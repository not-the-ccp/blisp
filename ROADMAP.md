# BLisp: north star and major milestones

BLisp should not become “JavaScript in Bash”, “Python with pipes”, or “Lisp with optional
braces”. Those are useful sources of ideas and useful failure cases, not identities.

The intended language is a **small, general-purpose dynamic language optimized for
composition, editability, and user-defined abstraction**. It keeps the Lisp ideas that make
code and abstraction unusually powerful, while treating Lisp notation as one peer notation
rather than the mandatory surface form. It keeps prototype delegation without inheriting
JavaScript's coercion and historical object-model accidents. It takes Python's general-purpose
scripting ambitions seriously without copying Python's expression-editing, lambda, import,
text/binary, and historical-API problems.

The strongest design test is:

> Can a library author build the next layer as ordinary BLisp code without privileged
> compiler/runtime knowledge, while ordinary application code remains easy to read, edit,
> debug, and reason about?

## Hard questions and current answers

### Why does BLisp exist if Python, JavaScript, Clojure, Julia, Raku, and Scheme already do?

Because the interesting combination is not currently the default in those languages:

- forward-growing, editor-friendly expression composition;
- ordinary brace/infix, layout, and S-expression notation as peer spellings;
- code-as-data and real metaprogramming;
- prototype-oriented objects with predictable receiver binding;
- full first-class closures rather than a restricted lambda sublanguage;
- protocol-driven user extensibility;
- explicit text/binary boundaries;
- a small semantic core whose standard library is mostly normal language code.

If BLisp eventually loses this combination and merely resembles another mainstream language
with alternate punctuation, there is no reason for it to exist.

### Is multiple syntax the point?

No. **One semantics, multiple useful notations** is a consequence of the language philosophy,
not the whole philosophy.

The language must never become a collection of parser tricks. Every accepted notation must
map deterministically to one semantic model. Tooling must be able to understand all of it.
When two spellings differ only cosmetically, they must not acquire different precedence,
scope, evaluation order, or dispatch behavior.

Long term, this suggests a formatter/rewriter able to render the same program in more than
one preferred notation while preserving semantics and, where practical, comments.

### What is the semantic core?

The target core is approximately:

- immutable literals and symbols;
- lexical bindings and closures;
- function application;
- conditionals and loops/control transfer;
- mutable property-bearing objects with prototype delegation;
- arrays, immutable list structure, strings, bytes, numbers, and lazy iterables;
- structured errors;
- protocol operations for iteration, callability, length, equality/hash, arithmetic,
  representation, indexing/slicing, and resource handling;
- code/syntax values plus hygienic expansion;
- capability-sized OS/runtime primitives.

`class`, destructuring, layout suites, pipelines, operator aliases, comprehensions, and most
other conveniences should remain explainable as syntax/protocol/library layers over that core.

### Is BLisp object-oriented, functional, or Lisp-oriented?

It should refuse the premise that one of those must own the language.

Functions are ordinary first-class values. Objects are ordinary delegating records. Methods
are receiver-aware calls, not a second category of function. Immutable/persistent structures
can coexist with mutable objects and arrays. Code can be represented as data without every
application being written as an S-expression.

The language should make all of these styles compose rather than force programs into one
paradigm.

### Is `proto` the real object model? Are classes real?

Prototype delegation is the semantic model. A class-like declaration may remain convenient
syntax, but it should not create a second inheritance universe.

Adding a convenience feature must not create “class objects” with rules unrelated to normal
objects, functions, properties, or prototypes.

### Should everything be a method?

No. Receiver syntax means actual prototype dispatch. Free functions remain equally important
and compose through pipelines. This keeps dispatch predictable and avoids turning every
algorithm into prototype pollution merely for fluency.

### How dynamic should BLisp be?

Dynamically typed is the current semantic center. That does not imply “no contracts” or “no
static tooling”. A future annotation/contract system should improve tooling, validation, and
optimization without creating a second subtly different language or making unannotated code
second-class.

A static type system should not be added until there is a stable semantic model worth typing.

### What should mutation mean?

Mutation is a first-class capability, not an embarrassment, but mutability must be visible in
semantic contracts. The current hashability rule is an example: mutable structural values are
not silently accepted as unstable hash keys.

BLisp should eventually provide excellent immutable/persistent collection libraries as well as
mutable arrays/objects/bytes, rather than declaring one style morally superior.

### What is a string?

This remains a foundational open decision and must be resolved before 1.0.

The likely contract is: a BLisp string is valid Unicode text, independent of the host locale,
with explicit UTF encodings at byte boundaries. We still need to decide exactly what indexing,
iteration, slicing, and `length` operate on (Unicode scalar values is the current leading
choice). Grapheme clusters belong in a higher text layer rather than silently redefining core
indexing.

The Bash implementation's inability to store NUL in shell strings is an implementation limit,
not language semantics.

### What is an integer?

Also unresolved at the language level. Inheriting Bash machine-word overflow is not acceptable
as the portable definition.

The likely options are:

1. unbounded integers by default, with explicit fixed-width integer/byte operations when
   required; or
2. a precisely specified fixed-width base integer plus bignums as a separate numeric kind.

For a Python/JS-class scripting language, unbounded default integers are currently the stronger
candidate, but this needs experiments and a second implementation before freezing it.

Floating-point semantics should be specified independently, most likely around IEEE-754 binary64
for the ordinary `float` type.

### Is `eval` the metaprogramming model?

No. `eval` is an escape hatch.

The long-term metaprogramming model should use first-class **syntax objects** carrying source
provenance and hygienic binding identity. Quasiquote is useful, but raw AST manipulation must
not force macro authors to recreate scope rules by hand. Expansion should preserve source
origins so errors point at code users recognize.

Runtime helpers and higher-order functions should be preferred when compile-time rewriting is
unnecessary.

### Should users be able to change the grammar?

Not yet, and probably not globally.

BLisp already has an unusually rich reader surface. Unbounded reader/operator extension can
make libraries impossible to parse without executing arbitrary setup and can destroy tooling.
If language-oriented programming is added, it should have explicit lexical/module boundaries
and produce ordinary syntax objects after a well-defined reader/expansion phase.

### What replaces `include`?

A real module system, not a smarter textual include.

`include` remains useful for ordered source composition. Modules should add:

- explicit exports;
- namespace/module values;
- stable package identities;
- relative and package imports;
- deterministic cycle semantics;
- no accidental global namespace injection;
- source provenance through the module graph.

### What is the error model?

Errors are structured values with stack/provenance information. Throw/catch is control flow,
not the representation of an error.

The language should distinguish ordinary recoverable errors from process termination and from
implementation failures. Library APIs should be able to define rich error domains without
subclassing a privileged built-in exception hierarchy.

### What is the resource-lifetime model?

GC and resource lifetime are different problems.

Files, sockets, subprocesses, locks, and future native handles need deterministic cleanup even
if heap objects are garbage-collected. BLisp should gain a small cleanup abstraction (`defer`,
`using`, scoped resource protocol, or a better design discovered through experiments) rather
than relying on finalizers.

Automatic GC must not be enabled until the runtime has a defensible root model. The Bash
reference implementation may continue using explicit collection longer than a production VM.

### What is the concurrency model?

Still open and important. It should not be copied from JavaScript just because promises are
familiar.

The likely direction is **tasks/futures plus structured cancellation and a generic readiness
primitive**, so schedulers, async I/O, worker pools, actors, and pipelines can be libraries.
`async`/`await` syntax may eventually be useful, but it should sit on a clear task/cancellation
model rather than define one accidentally.

### How does BLisp escape to the operating system or native code?

Subprocesses and raw streams are the portable lowest-common-denominator escape hatch today.
A serious implementation eventually needs a native-extension/FFI story. The language contract
should define capability boundaries; the Bash reference implementation is allowed to support a
smaller set than a production runtime.

### Is Bash supposed to remain the implementation forever?

No assumption should force that.

The Bash implementation is valuable because it stress-tests whether the language can be
implemented with primitive machinery and makes accidental complexity visible. It should be a
**reference implementation**, not the specification.

A second independent implementation is a major milestone because disagreement between two
implementations exposes accidental host semantics far more effectively than documentation
alone.

The likely serious implementation target is a small bytecode VM written in a systems language
(e.g. Rust), but that choice should follow the semantic specification rather than precede it.

### Should BLisp self-host?

Eventually, selectively. Self-hosting is a useful expressiveness and tooling test, not a badge.
A BLisp parser, formatter, package tooling, portions of the stdlib, and perhaps compiler passes
written in BLisp would be valuable. Rewriting a working low-level VM in BLisp merely to claim
self-hosting would not be.

## Milestones

### M0 — Semantic hardening (current)

Goal: stop accidental Bash/parser implementation details from being language semantics.

- deterministic mixed-syntax grammar;
- hygienic generated bindings;
- isolated process environment;
- coherent equality/hashability;
- one callable/prototype invariant;
- token-aware top-level source inclusion;
- lazy ranges;
- interpreter/compiler differential gates;
- source provenance beginning at parser diagnostics.

Exit condition: known core invariants are documented and every fixed invariant has adversarial
interpreter/compiler tests.

### M1 — Language constitution

Write a compact normative specification independent of Bash:

- values and truthiness;
- evaluation order;
- scope and binding;
- function/method/receiver semantics;
- prototype lookup and mutation;
- control flow and errors;
- equality/identity/hashability;
- iterator protocol;
- numeric semantics;
- string/bytes semantics;
- source/code/syntax values;
- observable process behavior.

Build a conformance suite that a second implementation can run without reading `runtime.sh`.

Exit condition: an implementer can answer “what should this program do?” from the spec/tests,
not from Bash behavior.

### M2 — Source model and tooling foundation

Move from token-index diagnostics to first-class source information:

- file IDs and spans;
- provenance through include/module graphs;
- AST/syntax-node source origins;
- generated-node origin chains;
- BLisp-level stack traces in interpreter and compiler;
- recoverable parser diagnostics where practical;
- CST/trivia representation for formatters/refactoring.

Build `blfmt` and an AST/CST inspection tool. Long term, formatting may support conventional,
layout-heavy, and S-expression-oriented house styles over the same semantics.

### M3 — Real modules and packages

Design modules as namespace/value boundaries rather than textual inclusion.

- explicit import/export;
- module values;
- deterministic initialization and cycles;
- package manifests and dependency identities;
- local package cache;
- reproducible resolution;
- version/toolchain metadata;
- no hidden network access during ordinary execution.

### M4 — Runtime completeness

Freeze the primitives needed for serious userland libraries:

- coherent Unicode strings;
- specified integers/floats;
- correct automatic memory management in a production runtime;
- deterministic resource cleanup;
- stream/readiness abstraction;
- structured tasks/cancellation;
- TCP server/listener primitives;
- filesystem/process/environment capability model;
- native extension/FFI boundary;
- cryptographic randomness and clocks with clear contracts.

The standard library should implement higher layers whenever these primitives suffice.

### M5 — Hygienic metaprogramming

Replace “AST plus `eval`” as the main compile-time story with source-aware hygienic syntax
objects and an explicit expansion phase.

Requirements:

- scopes/binding identity preserved mechanically;
- source provenance preserved;
- macros work across all peer surface notations because they consume syntax, not raw text;
- expansion is inspectable (`blisp expand`);
- ordinary functions remain preferable for ordinary runtime abstraction.

### M6 — Second implementation / real VM

Implement the language independently from the Bash runtime.

Likely shape:

- parser + expander;
- compact bytecode;
- interpreter/VM first;
- tracing/JIT/native compilation only if measurements justify it;
- precise GC;
- portable async/readiness backend;
- native FFI.

Run the same semantic conformance suite against Bash and the VM continuously.

The Bash implementation then becomes an unusually transparent reference and bootstrap/debug
implementation rather than the performance target.

### M7 — Standard library coherence

Grow batteries around abstractions, not module count.

Target areas include:

- collections and persistent collections;
- iterators/transducers/stream processing;
- text, Unicode, regex;
- binary codecs and structured binary I/O;
- path/files/temp/archive/compression;
- JSON/CSV/config/serialization;
- URLs/HTTP/TLS;
- subprocesses/concurrency;
- dates/times/time zones;
- math/statistics/random;
- testing/property testing/benchmarking;
- logging/diagnostics;
- CLI and application configuration.

Every module should have an explicit reason to exist. Avoid Python-style historical overlap
where several generations of API coexist indefinitely without a clear preferred abstraction.

### M8 — Developer experience

A serious language needs more than a parser and runtime:

- formatter;
- language server;
- semantic highlighting;
- go-to-definition/references/rename;
- debugger/profiler;
- package tooling;
- documentation generator;
- REPL with multiline/layout awareness;
- test runner and benchmark runner;
- AST/macro expansion explorer.

Because BLisp has peer notations, tooling correctness is also the proof that the syntax model is
coherent rather than a collection of parser heuristics.

### M9 — Large-program trials

Before calling the language stable, build substantial software in it:

- HTTP server/client stack;
- package manager pieces;
- parser/compiler or formatter;
- nontrivial CLI application;
- long-running concurrent service;
- data-processing workload;
- binary protocol implementation.

Track where programmers need runtime changes instead of libraries, where syntax becomes
ambiguous, where performance collapses, and where error messages lose useful provenance.

The purpose is to falsify the design, not demonstrate predetermined success.

### M10 — 1.0 semantic stability

Only after two implementations and large-program experience:

- freeze core semantics and grammar compatibility policy;
- define deprecation/versioning rules;
- publish conformance corpus;
- document implementation-defined capabilities explicitly;
- commit to source compatibility boundaries.

## Things BLisp should deliberately resist

- becoming JavaScript-compatible for compatibility's sake;
- adding a special runtime type every time a library is inconvenient to write;
- making every operation a method merely for fluent syntax;
- adding grammar aliases that subtly differ semantically;
- implicit string/bytes coercion;
- silent numeric coercion rules that are hard to predict locally;
- definition-time mutable defaults;
- global reader extensions that make files impossible to parse in isolation;
- macros as the first answer to ordinary abstraction problems;
- class semantics separate from ordinary objects/prototypes;
- finalizers as the primary resource-management strategy;
- treating Bash limitations as the portable specification;
- self-hosting as a goal independent of user value;
- accumulating stdlib compatibility fossils before the language even has users.

## The shortest possible north star

BLisp should become a language in which:

1. **expressions are easy to grow and refactor;**
2. **abstractions are ordinary values/protocols whenever possible;**
3. **syntax is plural but semantics are singular;**
4. **Lisp's code-as-data power survives without mandatory Lisp notation;**
5. **prototype delegation remains simple and unsurprising;**
6. **libraries can build almost everything above a small capability layer;**
7. **errors, source locations, and tooling are designed into representations;**
8. **the specification survives replacing Bash entirely.**


## Reference implementation fidelity rule

Embedded U+0000 is a required reference-implementation conformance case. Bash's inability to hold a NUL byte in a shell variable is an implementation detail, never a BLisp language restriction. The Bash runtime uses an encoded backing representation for strings that cannot be losslessly materialized in a shell variable; host APIs that themselves forbid NUL may reject such values at that boundary.
