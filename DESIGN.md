# BLisp language design notes

BLisp is a Lisp / brace-and-infix hybrid. The goal is not JavaScript compatibility,
Scheme compatibility, or Python compatibility. The goal is a small dynamic language
whose primitives are sufficient for ordinary libraries and whose syntax stays easy to
edit as programs evolve.

## Ergonomics is an expression-model property

A recurring failure mode in expression-oriented languages is *outside-in editing*.
Suppose `s` is a string and a function initially returns it:

```blx
return s;
```

As requirements grow, a Python-style nested-call formulation repeatedly wraps the old
expression and forces edits at both ends. BLisp makes linear transformation a first-class
expression pattern:

```blx
return s
  |> .encode("utf-8")
  |> .length
  |> text.formatInt(16)
  |> text.chars
  |> .join("-");
```

Each new transformation is normally appended. This is not merely formatting sugar; it
is the intended way to compose transformations.

### Pipeline rules

```blx
value |> f              // f(value)
value |> f(a, b)        // f(value, a, b)
value |>> f(a, b)       // f(a, b, value)
value |> f(a, $, b)     // f(a, value, b)
value |> $ * 2 + 1      // value * 2 + 1
value |> .trim()        // value.trim()
value |> .length        // value.length
```

The `$` hole can occur inside an arbitrary pipeline stage, not merely directly inside a
call. Thread-first is the normal convention for BLisp library functions; thread-last and
`$` exist so foreign/legacy/naturally-different APIs do not force adapter lambdas.

Clojure's `->`, `->>`, and `as->` demonstrate why first-only threading is insufficient:
real APIs naturally place their subject in different argument positions. BLisp combines
those cases in one expression system rather than requiring several macros.

## Operators have one identity and several spellings

Operator spelling is lexical sugar, not semantics. Each operator has one canonical identity
and may expose a symbolic spelling, a readable English spelling, and the canonical identifier
itself:

```blx
x + y
x plus y
x add y

x <= limit
x at_most limit
x le limit

item @ values
item in values

value |> transform
value pipe transform
value pipe_first transform
```

All spellings have exactly the same precedence, associativity, short-circuit behavior,
protocol dispatch, and AST identity. Changing spelling must never change program meaning.
Canonical names use identifier-safe underscores where necessary (`range_inc`, `pipe_first`,
`not_instanceof`, etc.).

English aliases are part of the core language because they provide a useful readable
alternative without changing the source language. Additional natural-language vocabularies
(such as German or French) are deliberately not global core keywords: if added, they should
be optional lexical profiles that canonicalize to these same operator identities before
parsing, so libraries do not fragment by spoken-language keyword set.

## `.` means receiver dispatch, not free-function lookup

Prototype lookup is dynamic and receiver-sensitive:

```blx
obj.method(x)
```

looks up `method` through `obj`'s prototype chain and invokes it with `this == obj`.
Detaching the function is observably different:

```blx
let f = obj.method;
f(x);                    // no implicit obj receiver
```

BLisp deliberately does **not** use D-style UFCS fallback where `x.f()` may mean either a
method or `f(x)`. In a dynamic prototype language that would make a later property added
to a prototype silently change dispatch. Free functions compose through `|>` instead.

## Functions should not have a crippled lambda sublanguage

Python lambdas are intentionally restricted to one expression. BLisp has one closure
semantics exposed through several convenient spellings:

```blx
x => x * x

x => {
  let y = expensive(x);
  log(y);
  return y * y;
}

fn(x) {
  // same full language in the body
}
```

Higher-order APIs also accept trailing full closures:

```blx
let total = fold(values, 0) { acc, x =>
  let next = acc + x;
  next;                  // block value; explicit return is also allowed
};

let squares = values.map { x => x * x };
```

For partial application, a bare `?` in a call is a positional hole:

```blx
let parseHex = text.parseInt(?, 16);
let surround = join(?, "[", ?);   // two-argument closure
```

This produces ordinary closures; it is not a separate callable type.

## Defaults are evaluated at call time

```blx
fn connect(host, timeout = 5000, retries = 3, ...rest) { ... }
```

Default expressions run when the argument is omitted and may refer to earlier parameters.
That intentionally avoids Python's definition-time mutable-default trap:

```blx
fn fresh(xs = []) {
  xs.push(1);
  return xs;
}

fresh();  // [1]
fresh();  // [1], not [1, 1]
```

Required positional parameters must precede defaulted parameters. A rest parameter, if
present, is last.

## Slicing is protocol-shaped syntax

```blx
s[2:]
s[:5]
s[2:5]
```

lowers to the value's `slice` method. It therefore works for strings, arrays and bytes
without hard-coding three separate grammar constructs, and user-defined types can
participate by providing a compatible method.

## Methods versus functions

Operations naturally owned by a value are methods:

```blx
textValue.encode("utf-8")
bytesValue.decode("utf-8")
array.push(value)
```

Algorithms and cross-type transformations remain ordinary functions/namespaced functions:

```blx
text.formatInt(number, 16)
json.parse(source)
seq.map(source, f)
```

Pipelines make both equally chainable, so there is no need to put every algorithm on every
prototype merely for fluent syntax.

## Numeric tower

Integers and floats are distinct representations but one numeric equality domain:

```blx
4 == 4.0      // true
4 === 4.0     // false
hash(4) == hash(4.0)  // true
```

Hashing follows equality. `===` / `is` exists for representation/identity-sensitive code.

## Equality and hashability are one contract

For every hashable pair `a` and `b`, `a == b` implies `hash(a) == hash(b)`. Hash-based
containers may rely on that invariant rather than searching unrelated buckets to compensate
for broken keys.

Mutable structurally-equal builtins are therefore not hashable:

```blx
hash([1, 2])       // throws :unhashable
hash(b"\x01")    // throws :unhashable
```

Immutable Lisp cons/list structure is structurally hashable. Plain objects/functions use
stable identity hashing while they use identity equality. An object that defines `__eq__`
becomes unhashable unless it also supplies a compatible integer-returning `__hash__`.
A user-defined hash must remain stable for as long as the value is used as a hash key; the
runtime can enforce built-in mutability rules but cannot prove arbitrary user code obeys
that protocol.

Structural equality itself is independent of hashability. Cyclic arrays compare with
cycle-safe bisimulation semantics rather than recursing forever, even though arrays cannot
be hash keys.

## Strings and bytes are intentionally distinct

Text does not silently become binary data. Encoding is explicit:

```blx
let payload = text.encode("utf-8");
let text2 = payload.decode("utf-8");
```

`bytes` can contain NUL and arbitrary octets. Bash-backed strings currently cannot contain
NUL; this implementation limitation is exposed instead of silently corrupting data.

## Library design principles

1. Prefer capability-sized runtime primitives over high-level builtins.
2. Prefer one coherent abstraction over several historical aliases.
3. Prefer generic protocols (`__iter__`, `__len__`, `__hash__`, etc.) over type-specific
   compiler cases.
4. Prefer lazy iteration where materialization is not inherently required.
5. Keep text/binary conversion explicit.
6. Keep identity (`is`) distinct from semantic equality (`==`).
7. Do not reproduce JavaScript coercion rules, Python mutable-default semantics, or legacy
   APIs merely because a source language has them.
8. Syntax additions must remove recurring structural friction, not just save a character in
   one special case.

## Implementation note

Hybrid syntax and S-expressions parse into the same internal AST because an interpreter and
compiler require a representation. Neither syntax is conceptually a frontend for the other;
they are peer syntaxes for the same language semantics.
