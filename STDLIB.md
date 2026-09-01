# Standard library direction

The BLisp standard library uses Python as a **coverage reference**, not an API template.
Python is a useful demonstration of what a general-purpose scripting environment eventually
needs: containers, iteration, text/binary codecs, filesystem and process facilities, paths,
serialization, networking, statistics, testing, CLI support, and so on. It also carries
several decades of compatibility constraints that BLisp does not need to inherit.

## Deliberate differences from Python

- No `os.path` / `pathlib` split: path manipulation lives under one `path` API.
- Text and bytes are separate and conversions are explicit.
- Default function arguments evaluate at call time; there is no mutable-default footgun.
- Lazy iteration is a first-class protocol and `seq` is lazy by default.
- Runtime facilities expose capabilities; formats/protocols such as Base64 and HTTP are
  implemented in BLisp where practical.
- One `tap(value, effect)` helper is preferred over a family of subtly-overlapping scope
  functions.
- `Result` helpers exist, but exceptions are ordinary thrown values; libraries are not forced
  into one error container.
- Deterministic PRNG (`prng`) is separate from OS/CSPRNG-backed `random` so reproducibility and
  security are not conflated.
- URL parsing is separate from percent-encoding primitives and does not reproduce the
  historical `urllib` module split.
- Time APIs will distinguish absolute instants, durations, and civil/calendar values rather
  than reproducing Python's naive/aware datetime ambiguity.

## Current modules

| Module | Purpose |
| --- | --- |
| `prelude` | HashMap, Set, Queue, Result helpers, byte reader/writer, `tap` |
| `collections` | deque, heap, counter, multimap and related containers |
| `seq` | lazy map/filter/take/drop/chain/zip/enumerate/fold/reduce |
| `functional` | compose, partial, once, memoize, retry, resource helpers |
| `search` | binary search/bisect and ordered insertion |
| `text` | Unicode code-point helpers, wrapping/padding, integer formatting/parsing |
| `path` | path normalization, joining, basename/dirname-style operations |
| `files` | walking, copying and line-oriented convenience helpers |
| `glob` | recursive pattern-oriented file discovery |
| `temp` | temporary files/directories |
| `io` | in-memory readers/writers, tee writer, copying, resource helpers |
| `math` | gcd/lcm/combinatorics/sqrt/clamp/numeric helpers |
| `stats` | mean/median/variance/stdev/quantiles/histograms |
| `fraction` | exact rational arithmetic implemented via numeric protocols |
| `random` | OS-random-backed integer/choice/shuffle/sample helpers |
| `prng` | deterministic seeded PRNG for tests/simulation |
| `binary` | binary readers/writers and integer encodings |
| `base64` | Base64 implemented in BLisp |
| `encoding` | hex and encoding namespace conveniences |
| `checksum` | Adler-32 and CRC-32 in BLisp |
| `json` | JSON parser/serializer with Unicode escape support |
| `csv` | CSV parsing/serialization |
| `ini` | simple INI/config parsing |
| `uri` | percent encoding and query encoding |
| `url` | structured HTTP/HTTPS URL parsing/formatting |
| `http` | HTTP client built over raw TCP (current implementation is intentionally small) |
| `regex` | policy helpers over the runtime POSIX-ERE capability |
| `uuid` | UUID v4 generation |
| `graph` | graph traversal and Dijkstra shortest paths |
| `cache` | bounded LRU cache |
| `events` | signal/event dispatcher |
| `cli` | command-line option parsing |
| `logging` | structured-ish logger |
| `testing` | suites/assertions/throw checks |

`lib/std.blx` includes the batteries above. Individual modules remain the normal choice when
startup matters.

## What should remain runtime primitives

The runtime should know about things libraries cannot manufacture safely or portably from
other language values: raw byte buffers, file descriptors/streams, environment/process
access, clocks, random bytes, raw sockets, low-level regex matching, object/prototype and
iteration protocols, hashing/equality hooks, and the evaluator/compiler machinery.

The runtime should generally **not** know about JSON, CSV, Base64, HTTP message syntax, LRU
caches, graphs, statistics, CLI option conventions, or similar policy-rich abstractions.
Those are proofs that the primitive layer is sufficient.

## Known gaps

The largest remaining general-purpose gaps are not missing convenience functions:

- safe automatic GC / lifetime management
- server/listening sockets and readiness polling/event-loop primitives
- TLS
- rigorous Unicode string indexing/normalization/grapheme APIs
- FFI/shared-library access
- stronger module/package semantics than ordered lexical `include`
- a real timezone/instant/civil-time library
- arbitrary-precision integers / decimal arithmetic
- richer stream buffering and compression primitives

These should be addressed before trying to imitate every small Python module.
