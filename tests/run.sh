#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p build

printf '%s\n' '[1/5] shell syntax'
bash -n blisp runtime.sh compiler.sh surface.sh layout.sh

parity_suite() {
  local name=$1 file=$2
  local exe="build/${name}-test"
  local interpreted="build/${name}-interpreted.out"
  local compiled="build/${name}-compiled.out"
  ./blisp run "$file" > "$interpreted"
  ./blisp compile "$file" -o "$exe" >/dev/null
  "$exe" > "$compiled"
  cmp "$interpreted" "$compiled"
  cat "$interpreted"
  printf '%s\n' "$name interpreter/compiler outcome identical"
}

printf '%s\n' '[2/5] ergonomics differential suite'
parity_suite ergonomics tests/ergonomics.blx

printf '%s\n' '[3/5] layout differential suite'
parity_suite layout tests/layout.blx

printf '%s\n' '[4/5] parenthesis grammar differential suite'
parity_suite grammar tests/grammar.blx

printf '%s\n' '[5/5] standard-library differential suite'
parity_suite stdlib tests/stdlib.blx
