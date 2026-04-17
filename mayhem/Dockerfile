FROM --platform=linux/amd64 ubuntu:22.04 AS builder

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cmake ninja-build clang-14 llvm-14-dev libmlir-14-dev libclang-14-dev \
    build-essential git

COPY . /repo
WORKDIR /repo/build
RUN cmake ../src -GNinja \
    -DVERONA_LLVM_LOCATION=/usr/lib/llvm-14 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER=clang++-14
RUN ninja verona-parser

FROM ubuntu:22.04
COPY --from=builder /repo/build/parser/verona-parser /
