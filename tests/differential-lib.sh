#!/usr/bin/env bash
# Shared helpers for semantic interpreter/compiler differential tests.
set -euo pipefail

BL_TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$BL_TEST_ROOT/build"

parity_suite() {
  local name=$1 file=$2
  local exe="$BL_TEST_ROOT/build/${name}-test"
  local interpreted="$BL_TEST_ROOT/build/${name}-interpreted.out"
  local compiled="$BL_TEST_ROOT/build/${name}-compiled.out"

  "$BL_TEST_ROOT/blisp" run "$BL_TEST_ROOT/$file" > "$interpreted"
  "$BL_TEST_ROOT/blisp" compile "$BL_TEST_ROOT/$file" -o "$exe" >/dev/null
  "$exe" > "$compiled"

  if ! cmp -s "$interpreted" "$compiled"; then
    printf 'differential mismatch in %s\n' "$name" >&2
    diff -u "$interpreted" "$compiled" >&2 || true
    return 1
  fi
  cat "$interpreted"
  printf '%s\n' "$name interpreter/compiler outcome identical"
}
