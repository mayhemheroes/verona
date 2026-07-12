#!/usr/bin/env bash
#
# mayhem/build.sh — build the Verona compiler, its fuzz harness, and its test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Produces:
#   /mayhem/verona-parser              in-process libFuzzer harness (ASan+UBSan+cov, DWARF-3)
#   /mayhem/verona-parser-standalone   run-once reproducer (same harness, no libFuzzer runtime)
#   /mayhem/build/                     cmake tree with the installed dist + registered ctest suite
#                                      (mayhem/test.sh only RUNS it)
#
# Verona pulls five deps via CMake FetchContent (trieste, fmt, snmalloc, re2, cli11). This build is
# AIR-GAPPED: the deps are vendored once (first, networked, build) into $VENDOR and thereafter the
# build re-runs OFFLINE from that cache (FETCHCONTENT_FULLY_DISCONNECTED). trieste pins snmalloc to a
# moving `main`; we pin the contemporaneous snmalloc SHA so the build is reproducible.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (base image exports these), with parameter-expansion fallbacks.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

# ─────────────────────────────────────────────────────────────────────────────
# 0) Vendor the FetchContent deps (once, networked) — thereafter the build is offline.
#    trieste/fmt/re2/cli11 are pinned to the SHAs verona@bfca50d / trieste@b466068 resolve to.
#    snmalloc is declared by trieste as a MOVING `main`; we pin it to a fixed main SHA that (a)
#    compiles under the base image's clang-19 — the older 2024-era snmalloc trips clang-19's hard
#    `-Wmissing-template-arg-list-after-template-kw` error in localalloc.h — and (b) passes Verona's
#    full golden-file suite with this trieste. Pinning a SHA keeps the build reproducible.
# ─────────────────────────────────────────────────────────────────────────────
VENDOR="${VENDOR:-$HOME/vendor}"
vendor_dep() { # <name> <url> <sha>
  local name="$1" url="$2" sha="$3"
  local dir="$VENDOR/$name"
  if [ -d "$dir/.git" ]; then return 0; fi
  echo "[build.sh] vendoring $name @ $sha"
  git clone --quiet "$url" "$dir"
  git -C "$dir" checkout --quiet "$sha"
}
mkdir -p "$VENDOR"
vendor_dep trieste  https://github.com/microsoft/trieste  b466068270471ccc9c5f5ddd543bd6e2fb02ad87
vendor_dep fmt      https://github.com/fmtlib/fmt         a33701196adfad74917046096bf5a2aa0ab0bb50
vendor_dep snmalloc https://github.com/microsoft/snmalloc 481b6484ab8b1dd5cdf01a855d97152d1df15752
vendor_dep re2      https://github.com/google/re2         4be240789d5b322df9f02b7e19c8651f3ccbf205
vendor_dep cli11    https://github.com/CLIUtils/CLI11      b9be5b9444772324459989177108a6a65b8b2769

# Defensive: drop snmalloc's `-Werror` from its build-affecting warning lines (identified by the
# accompanying `-Wundef`) so a stray clang-19 warning can't fail the build; leave the
# `check_cxx_compiler_flag` feature-probes (no `-Wundef`) intact.
sed -i '/-Wundef/ s/ -Werror//' "$VENDOR/snmalloc/CMakeLists.txt"

# trieste@b466068's CMake doesn't propagate snmalloc's include dir to trieste's own targets, so
# `#include <snmalloc/...>` from trieste headers needs the dir on the compile line explicitly. This
# is a compile include-path fix, NOT a sanitizer or source edit.
SNMALLOC_INC="-I$VENDOR/snmalloc/src"

FC_ARGS=(
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  -DFETCHCONTENT_SOURCE_DIR_TRIESTE="$VENDOR/trieste"
  -DFETCHCONTENT_SOURCE_DIR_FMT="$VENDOR/fmt"
  -DFETCHCONTENT_SOURCE_DIR_SNMALLOC="$VENDOR/snmalloc"
  -DFETCHCONTENT_SOURCE_DIR_RE2="$VENDOR/re2"
  -DFETCHCONTENT_SOURCE_DIR_CLI11="$VENDOR/cli11"
)

VERONA_SRCS=(src/lang.cc src/lookup.cc src/parse.cc src/subtype.cc)
while IFS= read -r p; do VERONA_SRCS+=("$p"); done < <(ls src/passes/*.cc)
HARNESS_INCS=(-I"$SRC/src" -I"$VENDOR/trieste/include" -I"$VENDOR/fmt/include"
              -I"$VENDOR/re2" -I"$VENDOR/cli11/include" "$SNMALLOC_INC")

# ─────────────────────────────────────────────────────────────────────────────
# 1) TEST BUILD (project's NORMAL flags): configure, build everything, install the dist. This
#    compiles re2/fmt/snmalloc and the golden-file testsuite runner that mayhem/test.sh will RUN.
# ─────────────────────────────────────────────────────────────────────────────
BUILD_DIR="$SRC/build"
cmake -S "$SRC" -B "$BUILD_DIR" -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SNMALLOC_INC $COVERAGE_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SNMALLOC_INC $COVERAGE_FLAGS" \
  "${FC_ARGS[@]}"
cmake --build "$BUILD_DIR" -j"$MAYHEM_JOBS"
cmake --install "$BUILD_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# 2) UNITY `verona` executable (NORMAL flags). Verona's multi-TU build SEGVs before main on a
#    static-init-order fiasco in wf.h's inline DSL globals; compiling all of src (incl. main.cc) as
#    ONE TU makes init order deterministic. Same sources, same flags — just one TU. Drop it in over
#    both binaries the ctest suite invokes (dist for golden tests; build/src for `verona test -f`).
# ─────────────────────────────────────────────────────────────────────────────
EXE_UNITY=/tmp/verona_exe_unity.cc
{ echo '#include <trieste/driver.h>'; echo '#include "lang.h"'
  for f in "${VERONA_SRCS[@]}" src/main.cc; do echo "#include \"$SRC/$f\""; done
} > "$EXE_UNITY"
"$CXX" -std=c++20 -O2 -DNDEBUG "${HARNESS_INCS[@]}" "$EXE_UNITY" \
  "$BUILD_DIR/_deps/re2-build/libre2.a" \
  "$BUILD_DIR/_deps/fmt-build/libfmt.a" \
  "$BUILD_DIR/_deps/snmalloc-build/libsnmallocshim-static.a" \
  -lpthread -latomic -o /tmp/verona-unity
cp /tmp/verona-unity "$BUILD_DIR/src/verona"
cp /tmp/verona-unity "$BUILD_DIR/dist/verona/verona"

# ─────────────────────────────────────────────────────────────────────────────
# 3) FUZZ HARNESS (unity: all of src EXCEPT main.cc, then the harness). Instrument the WHOLE Verona
#    front-end with $SANITIZER_FLAGS + $DEBUG_FLAGS so ASan/UBSan see Verona (not just the harness)
#    and backtraces resolve to Verona source with DWARF-3 symbols. re2/fmt are linked as plain deps.
# ─────────────────────────────────────────────────────────────────────────────
FUZZ_UNITY=/tmp/verona_fuzz_unity.cc
{ echo '#include <trieste/driver.h>'; echo '#include "lang.h"'
  for f in "${VERONA_SRCS[@]}"; do echo "#include \"$SRC/$f\""; done
  echo "#include \"$SRC/mayhem/verona-parser/verona-parser.cc\""
} > "$FUZZ_UNITY"

UBSAN_IGNORE="-fsanitize-ignorelist=$SRC/mayhem/verona-parser/ubsan-ignorelist.txt"
"$CXX" -std=c++20 -O2 -DNDEBUG $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_IGNORE $LIB_FUZZING_ENGINE \
  "${HARNESS_INCS[@]}" "$FUZZ_UNITY" \
  "$BUILD_DIR/_deps/re2-build/libre2.a" "$BUILD_DIR/_deps/fmt-build/libfmt.a" \
  -lpthread -latomic -o "$SRC/verona-parser"

# 3b) Standalone reproducer: same harness object, linked against the run-once driver instead of the
#     libFuzzer runtime (takes one input file, runs LLVMFuzzerTestOneInput once, crashes naturally).
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
"$CXX" -std=c++20 -O2 -DNDEBUG $SANITIZER_FLAGS $DEBUG_FLAGS $UBSAN_IGNORE \
  "${HARNESS_INCS[@]}" "$FUZZ_UNITY" /tmp/standalone_main.o \
  "$BUILD_DIR/_deps/re2-build/libre2.a" "$BUILD_DIR/_deps/fmt-build/libfmt.a" \
  -lpthread -latomic -o "$SRC/verona-parser-standalone"

echo "[build.sh] done: $(ls -la "$SRC"/verona-parser "$SRC"/verona-parser-standalone)"
