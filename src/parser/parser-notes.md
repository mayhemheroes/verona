# Parser Notes

* tests passing
  alloc.verona
  dnf.verona
  function.verona -> but why isn't it complaining about the + ?
* tests failing
  for-sugar

* lambdas
  * `var` is ref captured
  * `let` is value captured
  * all lambdas have a `self` parameter

* union_sub_t should ignore uninhabited branches of the disjunction
  * (U16 | U32) & (U32 | U64) -> U32
* free functions are singleton types with an apply method?
* inheritance
* params: infer & T, to help track regions?
* results: do we need a lower bounds?
* create sugar: do we need a concrete type?
  * related to static functions on interfaces

* make a `create` for everything, taking args of "fields without initialisers"
  * or make the initialisers the default values
* default value expressions can't have free variables
* allow `using` inside a function
* Ref[T] instead of update sugar
* distinguishing value parameters from type parameters
* constant expressions
* yield transformation
  https://csharpindepth.com/Articles/IteratorBlockImplementation
* trim indented strings

## Open Questions

* transform an object literal into an anonymous class and a create call
  needs free variable analysis
  could do the same thing for lambdas
  might not want to do either as they have type checking implications
* type parameters might need to have non-type constraints
* default capabilities for types

## Public/Private

* Public access only if the imported module path is not a prefix of the current module path (private access from submodules).
* Perhaps also allow private access if the current module path is a prefix of the imported module path (private access to submodules).
* do we want to be able to have private functions with symbol names?

## Anonymous Types

* anonymous interface types
* allow class/interface definition where a type is expected
  and also where an expr is expected?
* `'type' tuple` where a type is expected
  meaning the type of the expression
* `'interface' tupletype` where a type is expected
  meaning extract an interface from the type

## Overload Resolution

https://en.cppreference.com/w/cpp/language/overload_resolution
https://en.cppreference.com/w/cpp/language/constraints

find all candidate functions
  functions in scope
  functions on the receiver
  must have the same name
  must have a compatible arity, accounting for default parameter values

## Standard Library

env doesn't need stdin, stdout, stderr
  can use a capability to get access to them
use a capability to set the global exit code
use a capability to fetch args
use a capability to read and write envvars
main() gets ambient authority and nothing else
