#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p build

want=$'42\ntrue'
interp=$(./blisp run tests/include-fixtures/main.blx)
[[ $interp == "$want" ]] || { printf 'include interpreter mismatch:\n%s\n' "$interp" >&2; exit 1; }
./blisp compile tests/include-fixtures/main.blx -o build/include-test >/dev/null
compiled=$(./build/include-test)
[[ $compiled == "$want" ]] || { printf 'include compiler mismatch:\n%s\n' "$compiled" >&2; exit 1; }

if ./blisp run tests/include-fixtures/cycle-a.blx >build/include-cycle.out 2>build/include-cycle.err; then
  echo 'expected include cycle failure' >&2; exit 1
fi
grep -q 'include cycle' build/include-cycle.err

for bad in nested-explicit nested-layout; do
  if ./blisp run "tests/include-fixtures/$bad.blx" >"build/$bad.out" 2>"build/$bad.err"; then
    echo "expected top-level include failure for $bad" >&2; exit 1
  fi
  grep -q 'include is top-level only' "build/$bad.err"
done

if ./blisp run tests/include-fixtures/malformed.blx >build/include-malformed.out 2>build/include-malformed.err; then
  echo 'expected malformed include failure' >&2; exit 1
fi
grep -q 'include directive must occupy its source line' build/include-malformed.err

printf '%s\n' 'includes: 6 passed, 0 failed'
