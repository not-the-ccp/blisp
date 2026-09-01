# BLisp

BLisp is an experimental **Lisp / brace-and-infix hybrid language implemented in Bash**.
It has a tree-walking interpreter and a source-to-Bash compiler; compiled programs are
standalone Bash executables.

The language deliberately mixes conventional scripting syntax with first-class Lisp syntax
rather than treating one as a compatibility frontend for the other:

```blx
fn square(x) { return (* x x); }
let xs = 1..8;
let ys = xs.map { x => x * x };
println((foldl + 0 (toList ys)));
```

It also has prototype-oriented objects, lexical closures, mutable state, code-as-data,
quasiquote/unquote and `eval`, arrays/objects/lists/bytes, generic iteration,
user-definable protocols, structured thrown values, and direct OS/process/file/network
capabilities.

## Quick start

```sh
./blisp run examples/hybrid.blx
./blisp run examples/ergonomics.blx
./blisp evalx 'let x = 21; x * 2'
./blisp replx

./blisp compile examples/ergonomics.blx -o /tmp/ergonomics
/tmp/ergonomics
```

Classic Lisp source (`.bl`) is still accepted, while hybrid source normally uses `.blx`.

## Forward-growing expressions

BLisp treats linear expression growth as a language-level ergonomics goal. Instead of
repeatedly wrapping an existing expression, transformations can grow to the right:

```blx
return s
  |> .encode("utf-8")
  |> .length
  |> text.formatInt(16)
  |> text.chars
  |> .join("-");
```

Pipelines support first-position threading, last-position threading, arbitrary `$` holes,
and receiver/property stages:

```blx
x |> f(a)          // f(x, a)
x |>> f(a)         // f(a, x)
x |> f(a, $, b)    // f(a, x, b)
x |> $ * 2 + 1
x |> .trim()
x |> .length
```

This keeps real prototype method dispatch separate from free-function composition.

Other ergonomic features include:

```blx
// full block closures, including trailing closures
let ys = xs.map { x =>
  let y = x * x;
  y;
};

// partial application holes
let parseHex = text.parseInt(?, 16);

// call-time defaults; no Python mutable-default trap
fn f(x, options = [], ...rest) { ... }

// slicing lowers to the normal `slice` protocol/method
s[2:]
s[:5]
s[2:5]
```

See [DESIGN.md](DESIGN.md) for the rationale.

## Current implementation

Implemented language/runtime facilities include:

- integers and floats with cross-representation numeric equality, strings, symbols,
  booleans and `nil` / `null`
- binary-safe mutable byte buffers, including embedded NUL bytes
- Lisp cons cells/proper lists, arrays and prototype objects
- lexical closures, call-time default parameters, rest parameters, partial-application
  holes and mutable captures
- infix and prefix operators; `(f x y)` and `f(x, y)` coexist
- `if`, `cond`, `match`, `while`, `until`, `loop`, C-style `for`, and `for ... of`
- spread, destructuring, ranges, slicing, pipelines, arrows and trailing full closures
- `proto` declarations and prototype delegation, with receiver-aware method calls
- protocol hooks such as `__iter__`, `__len__`, `__str__`, `__call__`, `__eq__`, `__hash__`,
  and arithmetic/comparison methods
- quote, quasiquote/unquote and dynamic `eval`
- catchable structured failures via thrown values / `attempt`
- files and binary streams, environment variables, subprocesses, async subprocess handles,
  clocks, CSPRNG bytes and raw TCP clients
- explicit conservative garbage collection (`gc()`); automatic GC is intentionally not
  claimed correct yet

Hybrid includes are parsed as ordered source chunks rather than concatenated into one giant
source buffer. This materially improves the Bash parser's behavior for the growing stdlib
while retaining lexical include order and de-duplication.

## Standard library

Most higher-level facilities are written in BLisp itself under `lib/`. The runtime remains
capability-oriented; ordinary BLisp code implements containers, lazy sequences, JSON, CSV,
INI, Base64, checksums, exact rationals, graphs, LRU caches, URL handling, HTTP-over-TCP,
statistics, deterministic and OS-backed random utilities, CLI parsing, logging and tests.

Python is used as a coverage reference, not copied module-for-module. See
[STDLIB.md](STDLIB.md) for the module map, deliberate differences, and remaining primitive
gaps.

`lib/std.blx` is the batteries-included entry point. Individual modules remain preferable
when startup time matters in the current Bash implementation.

## Tests

```sh
./tests/run.sh
```

The focused ergonomics suite and the broad stdlib suite are checked in both the interpreter
and the standalone compiler path. Current local results are 8/8 ergonomics tests and 20/20
stdlib tests, with byte-for-byte interpreter/compiler output parity for both suites.

## Scope and limitations

BLisp is a serious implementation experiment, not a production VM. Important current gaps
include proven automatic GC, complete Unicode semantics, FFI, TLS, listening sockets/event
polling, arbitrary-precision integers, timezone/civil-time support, and a stronger
module/package system.

Those gaps are tracked as engineering constraints rather than hidden behind a claim of
JavaScript/Python compatibility: BLisp borrows useful ideas from Lisp and scripting
languages, but is its own language.
