#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source tests/differential-lib.sh

mkdir -p build/generated

case_no=0
run_case() {
  local kind=$1 file=$2
  ((++case_no)) || true
  parity_suite "generated-${case_no}-${kind}" "$file" >/dev/null
}

# Systematically vary small programs across semantic features.  These are not
# fuzz tests: every case is deterministic and the generated source is retained
# in build/generated on failure for immediate reproduction.
for n in 1 2 3 5 8; do
  file="build/generated/closure-$n.blx"
  cat > "$file" <<EOF
let bias = $n;
fn make(start) {
  let state = start;
  return fn(delta) {
    state += delta;
    return state * 2 + bias;
  };
}
let f = make($((n + 2)));
println(f($((n + 1))), f($((n + 3))), f(0));
EOF
  run_case closure "$file"
done

for n in 4 6 8 10 12; do
  file="build/generated/control-$n.blx"
  rem=$((n % 3))
  stop=$((n - 1))
  cat > "$file" <<EOF
let total = 0;
for (let i = 0; i < $((n + 4)); i++) {
  if (i % 3 == $rem) continue;
  if (i >= $stop) break;
  total += i;
}
println(total);
EOF
  run_case control "$file"
done

for n in 2 3 4 5 7; do
  file="build/generated/prototype-$n.blx"
  cat > "$file" <<EOF
let base = {
  factor: $n,
  calc(x) { return this.factor * x; }
};
let child = Object.create(base);
child.factor = $((n + 1));
println(child.calc($((n + 2))), "calc" in child, child.hasOwnProperty("calc"), child.hasOwnProperty("factor"));
EOF
  run_case prototype "$file"
done

for n in 1 2 4 7 9; do
  file="build/generated/exception-$n.blx"
  cat > "$file" <<EOF
fn classify(x) {
  if (x < 0) return throw({kind: "negative", value: x});
  return x * 2;
}
let caught = attempt(fn() { return classify(-$n); });
let clean = attempt(fn() { return classify($n); });
println(caught.ok, caught.error.kind, caught.error.value, clean.ok, clean.value);
EOF
  run_case exception "$file"
done

for n in 1 2 3 4 6; do
  file="build/generated/collection-$n.blx"
  cat > "$file" <<EOF
let xs = [$n, $((n + 1)), $((n + 2))];
xs.push($((n + 3)));
let ys = xs.map(x => x * 2).filter(x => x % 3 != 0);
let sum = ys.reduce(fn(a, b) { return a + b; }, 0);
println(ys.join(","), sum);
EOF
  run_case collection "$file"
done

printf 'GENERATED DIFFERENTIAL CASES PASSED: %d\n' "$case_no"
