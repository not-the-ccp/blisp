# BLisp semantic specification

Status: **pre-1.0 working normative specification**

This document defines BLisp in terms of observable language behavior, independently of the Bash reference implementation. `DESIGN.md` explains design intent and ergonomics; `ARCHITECTURE.md` describes the target implementation/tooling pipeline. This file is the semantic contract that implementations and conformance tests are expected to converge on.

BLisp is not defined by what Bash, `awk`, the host locale, or a particular parser implementation happens to do.

## Status vocabulary

Rules in this document are classified as follows:

- **Normative** — implementations must agree. A disagreement is an implementation bug or a specification bug that must be resolved explicitly.
- **Provisional** — this is the current intended semantics and implementations should agree, but the rule may deliberately change before 1.0.
- **Unresolved** — no portable program may rely on one observed behavior yet. The Bash reference implementation may exhibit a behavior, but that does not make it BLisp semantics.

Unless a section is explicitly marked provisional or unresolved, it is normative.

## 1. Programs and observable behavior

A BLisp implementation evaluates a program as a sequence of forms/statements in source order.

Observable behavior includes at least:

- produced values where the embedding interface exposes them;
- mutations to language-visible state;
- writes to language-visible I/O capabilities;
- thrown language values / structured runtime errors;
- process exit status and explicit termination;
- ordering of the above effects.

Performance, heap identities printed only by implementation-debug facilities, internal allocation order, generated Bash code, and internal representation are not language semantics.

The interpreter and compiler are execution strategies for the same language. A program does not acquire different semantics because it was compiled.

## 2. Core value domains

BLisp has the following semantic value families:

- `nil`;
- booleans `true` and `false`;
- integers;
- floating-point numbers;
- strings;
- mutable byte sequences (`bytes`);
- symbols;
- immutable cons/pair structure and proper lists;
- mutable arrays;
- ranges;
- property-bearing objects;
- callable values, including ordinary closures, builtins and bound callables;
- implementation/capability objects such as files, processes and streams where available.

An implementation may use any representation that preserves these semantics. In particular, Bash heap IDs such as `v123`, associative-array slots, shell strings, file descriptors and generated shell functions are not semantic value representations.

### 2.1 Truthiness

Only `false` and `nil` are falsey. Every other value is truthy, including:

- integer zero;
- floating zero;
- the empty string;
- empty arrays, lists, bytes and objects.

Boolean contexts do not perform user-defined numeric/string emptiness coercion.

### 2.2 Mutability

Arrays, bytes, ordinary property-bearing objects, and property sets on callable values are mutable.

Cons cells exposed by the ordinary language API are immutable unless a future specification explicitly introduces pair mutation.

Strings are immutable values.

## 3. Evaluation order

Evaluation order is **left to right** unless a construct explicitly states otherwise.

For an ordinary call:

```text
callee(arg1, arg2, arg3)
```

BLisp evaluates the callee first, then `arg1`, then `arg2`, then `arg3`, then performs the call.

For receiver calls:

```text
receiver.method(arg1, arg2)
```

BLisp evaluates the receiver and property/key expression as required by the surface form, then arguments left to right, then invokes the resolved callable with the original receiver as `this`.

Assignment evaluates the location/receiver/key components needed to identify the target and the assigned expression exactly once each according to the lowering contract of that assignment form. Surface lowering must not duplicate an expression merely because the construct is sugar. This rule is why nullish coalescing, pipelines, compound assignment and similar constructs use generated temporaries where necessary.

Short-circuit constructs are exceptions to eager operand evaluation:

- `and` / `&&` evaluates its right operand only when the left operand is truthy;
- `or` / `||` evaluates its right operand only when the left operand is falsey;
- nullish coalescing evaluates its right operand only when the left operand is `nil`;
- conditionals evaluate only the selected branch.

Equivalent operator spellings have identical evaluation order and short-circuit behavior.

## 4. Bindings and lexical scope

Function-local bindings are lexically scoped. A closure captures the lexical environment in which it is created, not the dynamic environment from which it is later called.

Assignment to a captured mutable binding updates the captured binding seen by subsequent calls.

A `const` binding cannot be reassigned through ordinary assignment. `const` applies to the binding, not recursively to the object reachable through the bound value.

Block/scope constructs that introduce a lexical scope do not retroactively change the identity of an outer binding with the same spelling.

Generated hygienic bindings are identified independently from source-spellable names. A generated temporary must not capture or be captured by user source merely because its debug spelling happens to match a user identifier.

### 4.1 Shadowing

**Provisional.** Where the current syntax accepts a new lexical binding with the same spelling as an outer binding, the inner binding shadows the outer one for its lexical extent. Future restrictions on unnecessary shadowing are a language-design question, but accidental implementation-level dynamic scoping is never permitted.

## 5. Functions and calls

Functions are first-class values. Storing a function in an object property does not permanently bind a receiver to that function.

```blx
let f = obj.method;
f();
```

is a detached ordinary call. It is observably different from:

```blx
obj.method();
```

which supplies `obj` as `this`.

### 5.1 Parameter binding

A call validates the complete parameter shape and arity before installing argument bindings for that call.

For a function with exactly `N` required/default-resolved positional slots and no rest parameter, a call whose final supplied/resolved arity is not `N` is an arity error.

For a function with `N` required positional slots and a rest parameter, fewer than `N` arguments is an arity error; remaining arguments are collected in source order into the rest binding.

Default expressions are evaluated at call time when their argument is omitted. A default may refer to earlier parameters. Default expressions are not shared definition-time values merely because they are syntactically literal containers.

### 5.2 Return

`return value` transfers control to the nearest enclosing function call and produces `value` as that call's result. A bare return produces `nil` unless a surface form specifies an equivalent unit spelling.

`return`, `break`, and `continue` are control transfers, not ordinary thrown user exceptions.

### 5.3 `this`, `call`, `apply`, and `bind`

A receiver call supplies the receiver as `this`.

An ordinary detached call has no implicit receiver; its `this` value is `nil` unless an explicit call facility supplies another value.

Callable `.call`, `.apply`, and `.bind` behavior is provided through the common Function prototype contract. All ordinary callable kinds participate in that contract; interpreted closures and compiled closures are not different semantic species.

## 6. Objects, properties, and prototypes

Property lookup follows an object's internal prototype chain until an own property with the requested key is found or the chain reaches `nil`.

Property assignment writes an own property on the target object unless a future explicitly specified descriptor mechanism says otherwise. Ordinary assignment does not search upward and mutate the prototype that supplied a previous inherited value.

Prototype cycles are invalid and must be rejected when an operation attempts to create one.

Functions are property-bearing values and may themselves participate in prototype delegation. Constructor `.prototype` objects and the callable value's own internal Function prototype are distinct concepts.

### 6.1 Method calls

Method syntax is receiver dispatch, not UFCS fallback. Failure to find a method does not cause BLisp to reinterpret `x.f(y)` as `f(x, y)`.

Looking up a function-valued property produces the function value. Receiver binding occurs because of the call form, not because property lookup secretly creates a permanently bound method object.

### 6.2 Constructors and `instanceof`

**Provisional.** `new F(args...)` creates a new object whose prototype is `F.prototype`, invokes `F` with that object as `this`, and yields the created object under the current constructor model. The exact policy for an explicit object returned by a constructor remains subject to pre-1.0 review and must not silently copy JavaScript behavior by accident.

`instanceof` follows the object's prototype chain against the constructor's prototype according to the constructor/prototype model; it is not structural type checking.

## 7. Equality, identity, and hashing

BLisp distinguishes identity/representation-sensitive comparison from semantic equality.

### 7.1 Numeric equality

Integers and floats currently occupy one numeric semantic-equality domain: numerically equal integer/float values compare equal under semantic equality. Their hashes must therefore agree whenever they are both hashable and equal.

The exact floating-point domain is unresolved in section 12; this equality rule does not by itself define NaN or infinity behavior.

### 7.2 String equality

Strings compare by their sequence of Unicode scalar values. Internal UTF-8 storage, a Bash fast path, or encoded backing storage is not observable.

### 7.3 Structural equality

Arrays compare structurally by element sequence under semantic equality. Recursive/cyclic structures must be handled without unbounded recursion; equality of cyclic arrays follows the recursive relation represented by their corresponding graph structure rather than heap ID alone.

Cons/list structure compares recursively and structurally.

Mutable bytes compare by byte sequence.

Objects and callable values use identity equality unless they participate in the specified custom equality protocol.

### 7.4 Hashability

If `a == b` under the equality relation used for hash keys, then `hash(a) == hash(b)` must hold whenever both are hashable.

Values whose built-in structural equality can change through ordinary mutation are not hashable by default. In particular:

- mutable arrays are not hashable by default;
- mutable bytes are not hashable by default;
- immutable cons/list structure may be structurally hashable;
- strings and symbols are hashable by value;
- identity-equal property-bearing objects may use a stable identity hash;
- an object defining semantic `__eq__` without a compatible `__hash__` is unhashable.

A user-defined `__hash__` must remain stable while the value is used as a key and must agree with user-defined equality. Violating that protocol is a program error.

## 8. Iteration

Iteration is ordered and pull-based at the semantic boundary.

Built-in iteration order is:

- array: increasing integer index;
- bytes: increasing byte index, yielding integer octet values;
- string: increasing Unicode scalar-value index, yielding one-scalar strings;
- proper list: car-to-cdr order;
- range: numeric range order according to the range's start/end/inclusivity/step semantics.

User-defined iterable objects participate through the iteration protocol rather than through implementation-specific type tests.

`for ... of ...` obtains an iterator once, repeatedly requests the next item, binds each yielded value, and handles `continue`/`break` according to ordinary loop control semantics.

A C-style `for (init; condition; step)` executes `step` after a `continue` from its body. Lowering that accidentally skips the step is a semantic bug.

## 9. Strings and bytes

### 9.1 Abstract string model

A BLisp string is an immutable sequence of Unicode scalar values.

The following operations are defined in scalar-value units, not UTF-8 bytes and not grapheme clusters:

- `length`;
- integer indexing;
- slicing;
- iteration;
- `charAt`;
- string `indexOf` result positions.

Combining sequences therefore may have length greater than one even when a user perceives one grapheme. Grapheme segmentation belongs to a higher-level text facility.

### 9.2 Embedded U+0000

U+0000 is an ordinary valid string scalar value.

The reference implementation **must not** reject, truncate, convert to bytes, or otherwise weaken a BLisp string because Bash variables cannot contain raw NUL. It must use an internal representation that preserves the language value losslessly.

A host API whose *own contract* forbids NUL may reject such a string at that host boundary. For example, POSIX pathnames and process argument/environment entries cannot contain an embedded NUL. That boundary restriction is not a restriction on BLisp strings in general.

### 9.3 UTF-8

`string.encode("utf-8")` produces the canonical UTF-8 byte sequence for the string's scalar values.

`bytes.decode("utf-8")` succeeds only for valid UTF-8 representing Unicode scalar values. It must reject, at minimum:

- invalid continuation structure;
- truncated sequences;
- overlong encodings;
- surrogate code points;
- code points above U+10FFFF;
- invalid leading bytes.

Decoding `00` yields a one-scalar string containing U+0000.

### 9.4 Bytes

Bytes are a mutable sequence of integers in `0..255`. Byte indexing and byte length are octet-based and independent of locale or text encoding.

Text decoding is explicit. A bytes value does not become text merely because its current contents happen to be valid UTF-8.

### 9.5 Case conversion and normalization

**Unresolved.** Core scalar indexing is locale-independent. The exact Unicode version and locale policy for upper/lower case mapping is not yet normative. Normalization is not implicitly performed by equality, hashing, indexing, encoding, or decoding.

Canonically equivalent but differently encoded Unicode scalar sequences are therefore not automatically equal unless a future normalization API is explicitly invoked.

## 10. Errors and exceptions

`throw x` throws the language value `x`. User code may throw any value.

`attempt(f)` (or its eventual lower-level equivalent) distinguishes successful return from a thrown language value and exposes the thrown value without converting it to a formatted stderr string.

Runtime capability failures intended to be catchable should use structured language error values with a stable error kind and message/data fields rather than relying on parsing rendered diagnostics.

**Provisional gap:** the Bash reference implementation still has paths that report an implementation/runtime error by writing stderr and returning failure instead of producing the eventual structured language error form. Those paths are conformance debt; they do not establish that stderr text is the preferred language-level exception model.

Syntax/reader errors occur before program execution and are diagnostics rather than user `throw` values. They must preserve source provenance.

## 11. Control flow

A conditional evaluates its condition exactly once and evaluates exactly one selected branch.

`while` repeatedly tests its condition before each body execution.

`break` exits the nearest enclosing loop.

`continue` transfers to the next iteration of the nearest enclosing loop. For C-style loops this includes executing the loop step expression before the next condition check.

Function return does not get consumed by an intervening loop; it crosses loop boundaries until the current function boundary consumes it.

## 12. Numbers

### 12.1 Integers

**Unresolved.** The current Bash reference implementation uses host shell arithmetic, which commonly behaves like signed machine-word arithmetic. Integer width, overflow, division edge cases and shift semantics are not yet portable BLisp guarantees merely because Bash exhibits them.

Before 1.0 BLisp must choose and test one model, such as arbitrary-precision integers or a specified fixed-width/two's-complement domain with explicit checked/wrapping operations.

Portable code must not currently depend on overflow behavior.

### 12.2 Floating point

**Unresolved.** The current reference implementation delegates significant floating arithmetic to host `awk`. BLisp has not yet normatively fixed IEEE-754 format, rounding behavior, NaN/infinity semantics, signed zero, conversion edge cases, or reproducibility requirements.

Portable code may use ordinary finite arithmetic covered by conformance tests, but edge behavior remains pre-1.0 specification work.

### 12.3 Bit operations

**Provisional.** Bit operations currently operate on integer values. Their exact width/sign semantics remain coupled to the unresolved integer model and must be finalized with it.

## 13. Source syntax and lowering

BLisp's peer source notations are different spellings/readers for one semantic language.

Operator aliases canonicalize to one semantic operator identity. Replacing `+` with its supported word/canonical spelling must not alter precedence, associativity, protocol dispatch, evaluation order, or result.

Surface sugar must preserve single evaluation of source expressions where the corresponding core operation requires it. Generated bindings used to achieve this are hygienic and are not user-visible lexical names.

Quoted ordinary data does not semantically acquire source-span metadata merely because compiler/tooling syntax objects track provenance out of band.

## 14. Includes and future modules

Current `include` is deterministic source composition, not the final semantic module system. It must preserve source identity for diagnostics.

A future module system will define module identity, initialization, imports/exports, cycles and package resolution separately from textual inclusion. Portable programs must not infer future module semantics from incidental filesystem behavior of `include`.

## 15. Host capabilities and I/O

Filesystem, process, environment, clock, randomness and networking operations cross from BLisp values into host capabilities.

At a host boundary:

1. BLisp values are validated according to the capability's semantic contract;
2. a host-specific representability restriction may cause a structured unsupported/value/I/O error;
3. the restriction must not be generalized into an unrelated core-language restriction.

Text file and stream I/O that is specified as UTF-8 text must preserve the complete encoded string, including embedded zero bytes in file/stream content. Pathnames and process argv/environment are separately constrained by host OS interfaces.

Environment mutation exposed by BLisp operates on the language-visible process environment abstraction; it must not permit ordinary source names to overwrite interpreter implementation variables.

## 16. Program termination

Normal completion has successful termination status when executed as a process unless the embedding API specifies another result channel.

An explicit `exit(n)` requests process termination with status `n` subject to the finalized integer/range policy for exit codes.

An uncaught thrown language error or fatal runtime error causes unsuccessful program termination when run as a process. The exact mapping from structured error categories to numeric process statuses is **provisional** except where a conformance test/spec entry explicitly fixes one.

Interpreter and compiled executable must agree on success versus failure and on all language-visible output/effects before termination.

## 17. Implementation-defined and implementation-private behavior

An implementation may differ in:

- allocation strategy and garbage collector;
- internal string representation;
- bytecode/native/generated-shell representation;
- object addresses/heap IDs not exposed through a normative identity operation;
- optimization strategy;
- diagnostic formatting details that are not designated stable tooling data;
- availability of optional host capabilities explicitly marked as such.

An implementation may **not** use this section to weaken a core semantic guarantee. In particular, inability of a host implementation language to represent a valid BLisp value directly requires indirection/encoding/emulation, not silently shrinking the BLisp value domain.

## 18. Conformance requirements

A conforming execution implementation must run the implementation-independent semantic corpus for every normative rule it implements.

The Bash interpreter and Bash compiler must run the same corpus. A future independent implementation/VM must run that corpus without translating expected results into Bash-specific conventions.

When two implementations disagree:

1. inspect this specification and the conformance case;
2. if the rule is clear, fix the disagreeing implementation;
3. if the rule is ambiguous or unresolved, make an explicit language-design decision and update both spec and tests;
4. do **not** automatically declare the Bash behavior canonical merely because it existed first.

## 19. Open semantic decisions before 1.0

The following remain intentionally unresolved and should have explicit design experiments/issues rather than accidental answers:

- integer width/overflow model;
- precise floating-point model;
- exact Unicode case-mapping/version/locale policy;
- constructor explicit-return semantics;
- final structured runtime-error hierarchy;
- module/package initialization and cycle semantics;
- resource lifetime / deterministic cleanup semantics;
- concurrency/cancellation semantics;
- whether and how open generic functions / protocol dispatch extend the prototype model;
- stable process exit-code mapping for uncaught language errors.

This list is not permission for implementation drift. Each unresolved item should become normative before BLisp 1.0 or be explicitly designated implementation-defined with a compelling reason.
