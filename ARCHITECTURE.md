# BLisp language architecture

This document describes the **target language/tooling architecture**, not the current Bash file
layout. The Bash implementation is a reference implementation and is allowed to reach the same
semantics by simpler means while the architecture is being built.

The central constraint is that BLisp has several peer surface notations but only one language.
That means syntax must become structured, source-aware data *before* semantic expansion, and
semantic expansion must converge on one small core representation.

## Target pipeline

```text
source bytes
    │
    ▼
UTF-8 / source manager
    │  file identity, offsets, line map
    ▼
reader / lexer / layout
    │  tokens + trivia + exact source spans
    ▼
concrete syntax tree (CST)
    │  preserves comments, delimiters, spelling and chosen notation
    ▼
normalized syntax objects
    │  canonical operator identity
    │  lexical binding identity
    │  source/provenance chain
    ▼
expansion
    │  layout/convenience lowering
    │  hygienic macros
    │  module binding/import resolution
    ▼
small core IR
    │  lexical variables / closure / call
    │  conditional / loop / control transfer
    │  object property/prototype primitives
    │  literal/core value construction
    │  structured errors and capability primitives
    ▼
semantic passes
    │  validation, lexical resolution, optional optimization
    ├─────────────────────┐
    ▼                     ▼
interpreter          bytecode compiler
                          │
                          ▼
                         VM
```

The current Bash implementation skips or conflates several boxes: `surface.sh` often parses a
surface construct and immediately emits a runtime cons-tree core form. That was appropriate for
bootstrapping, but it should not become the permanent architecture.

## Why a CST and syntax objects are both needed

An AST alone is insufficient for BLisp tooling because the following programs may have the same
meaning while intentionally using different notation:

```blx
f(x + 1)
```

```blx
(f (+ x 1))
```

```blx
f
    x + 1
```

A formatter, refactoring tool, source mapper, and syntax-style converter need to know what the
programmer actually wrote. The **CST** preserves spelling, delimiters, whitespace/layout and
comments.

A macro or compiler pass should normally not care whether addition was spelled `+`, `plus`, or
`add`, or whether an application used call parentheses or vertical indentation. The
**normalized syntax object** therefore carries canonical semantics plus source provenance.

This separation lets BLisp satisfy both sides of “syntax is plural, semantics are singular.”

## Syntax objects

A syntax object should eventually contain at least:

- datum/node kind and children;
- exact source span;
- source/module identity;
- lexical scope/binding identity;
- origin chain for generated/lowered code;
- optional pointer back to the CST/source spelling;
- properties/annotations used by tools and expansion.

The programmer-visible `quote` family can still produce ordinary data. Compile-time expansion
should operate on syntax objects rather than naked cons cells so hygiene and diagnostics are
mechanical rather than conventions.

A useful conceptual split is:

```text
quote          -> ordinary data
syntax         -> source-aware hygienic syntax value
quasiquote     -> ordinary-data construction
quasisyntax    -> syntax-object construction preserving scopes/origins
```

Exact spellings are intentionally not frozen yet.

## Expansion must be explicit

BLisp already performs substantial lowering: pipelines, defaults, destructuring, classes,
`match`, layout and other surface conveniences eventually become a smaller set of forms.
Today that lowering is distributed through parser functions.

Long term it should be an inspectable phase:

```sh
blisp expand program.blx
```

should show the expanded program in a canonical representation, with an option to show source
origins for generated nodes.

This is also the right place for hygienic user macros later. Raw textual macros or arbitrary
pre-lexer substitution are deliberately outside the target model.

## Reader extension and language extension

The reader is intentionally more conservative than the macro expander.

BLisp should not let arbitrary dependencies globally mutate punctuation/lexing for all files.
That destroys standalone parsing, editor tooling and reproducibility. If alternate readers or
DSL-oriented language variants are eventually supported, they should be selected explicitly at
a file/module boundary and still produce ordinary syntax objects for the common expander.

The current three peer notations are part of the standard reader, not runtime reader mutations.

## Modules are semantic, `include` is textual composition

`include` currently provides deterministic top-level source composition. It should remain small.
A real module system belongs after the reader and before/within expansion, where bindings are
known.

Modules should eventually have:

- an identity independent of filesystem spelling;
- explicit imports and exports;
- namespace/module values where useful;
- well-defined initialization and cycle semantics;
- separate compile-time and runtime dependencies if macros require them;
- preserved source provenance;
- deterministic package resolution.

A module should not work by injecting a pile of unqualified names into an unrelated file.

## Object model versus generic abstraction

Prototype delegation remains the object representation and receiver-dispatch model. It is good
at behavior that naturally belongs to one receiver.

That does **not** settle the expression problem or symmetric operations. Before 1.0 BLisp needs
an experiment comparing three extension mechanisms:

1. prototype protocol hooks (`obj.__iter__`, `obj.__add__`, etc.);
2. named open generic functions/protocols that can be extended independently of the value's
   prototype owner;
3. limited multiple dispatch for genuinely symmetric operations.

The experiment should implement the same nontrivial library abstractions using each model and
measure ambiguity, monkey-patching risk, tooling complexity and user ergonomics. Do not add all
three merely because each is powerful.

## Execution semantics should not depend on the implementation route

Interpreter and compiler are two implementations of the same core semantics, not two language
modes. The differential suites should eventually compare structured outcomes:

- returned value;
- structured error value;
- observable mutations;
- stdout/stderr bytes;
- exit status;
- source-level stack trace;
- module initialization effects.

When the future VM exists, the same conformance corpus becomes a three-way oracle rather than
being rewritten for the VM.

## Diagnostics architecture

The first source-provenance work is now in the Bash implementation: hybrid lexer/parser errors
know source file, line and column, including included chunks and layout rewriting.

The next stages are representation changes rather than prettier strings:

1. every CST/syntax/core node gets a span or origin;
2. calls push BLisp-level frames containing function identity + call-site origin;
3. thrown error values capture/retain a structured trace;
4. compiler-generated operations retain the same source origins;
5. the human renderer becomes only one consumer of structured diagnostic data.

The LSP, debugger and test runner should consume the same structured source information.

## Runtime architecture

The language specification should define capabilities, not Bash implementation tricks. A future
VM likely needs these layers:

```text
value model / GC
object + prototype engine
call/closure engine
iterator + protocol dispatch
bytecode interpreter
structured errors/traces
module loader
scheduler/readiness
filesystem/process/network capabilities
FFI/native extension layer
```

The VM does not need to mirror Bash heap handles or associative-array representations.

## Optimization philosophy

BLisp should first make generic code *semantically* cheap to express. Optimization then targets
the stable semantics.

Preferred order:

1. avoid accidental asymptotic mistakes (lazy ranges, sensible collection algorithms);
2. compile lexical names/locals rather than repeated dynamic string lookup where semantics allow;
3. cache stable property/prototype lookup;
4. specialize bytecode based on observed value kinds only when invalidation semantics are clear;
5. consider JIT/native compilation only after profiling shows bytecode dispatch is the dominant
   remaining cost.

A complicated optimizing JIT is not a milestone by itself.

## What the Bash implementation is for

The Bash implementation has three long-term values even after a VM exists:

- executable specification/conformance oracle;
- extremely transparent implementation for learning/debugging;
- pressure test for whether a proposed abstraction actually requires privileged machinery.

It should not force the language to inherit Bash integer width, locale behavior, NUL/string
limitations, process-launch costs, dynamic scoping of shell locals, or GC constraints.

## Near-term architectural sequence

The next architecture work should proceed in this order:

1. finish source provenance through syntax/core nodes and runtime frames;
2. extract and document a small core IR instead of lowering directly into undocumented runtime
   cons patterns;
3. introduce syntax-object metadata/hygienic origin tracking;
4. freeze the first normative semantic specification + conformance corpus;
5. design real modules on the binding/expansion model;
6. prototype a second implementation/bytecode VM;
7. only then make major compile-time language-extension facilities public.

This ordering intentionally puts representation and semantics before a macro system. A macro
system built on today's naked runtime cons trees would make every later source/tooling change
more expensive.
