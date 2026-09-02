#!/usr/bin/env bash
# Shared helpers for semantic interpreter/compiler differential tests.
set -euo pipefail

BL_TEST_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$BL_TEST_ROOT/build"

capture_outcome() {
  local prefix=$1; shift
  local had_e=0 status
  [[ $- == *e* ]] && had_e=1
  set +e
  "$@" > "$prefix.stdout" 2> "$prefix.stderr"
  status=$?
  (( had_e )) && set -e
  printf '%d\n' "$status" > "$prefix.status"
}

compare_outcomes() {
  local name=$1 left=$2 right=$3 failed=0
  if ! cmp -s "$left.status" "$right.status"; then
    printf 'differential status mismatch in %s\n' "$name" >&2
    printf '%s: ' "$left" >&2; cat "$left.status" >&2
    printf '%s: ' "$right" >&2; cat "$right.status" >&2
    failed=1
  fi
  if ! cmp -s "$left.stdout" "$right.stdout"; then
    printf 'differential stdout mismatch in %s\n' "$name" >&2
    diff -u "$left.stdout" "$right.stdout" >&2 || true
    failed=1
  fi
  if ! cmp -s "$left.stderr" "$right.stderr"; then
    printf 'differential stderr mismatch in %s\n' "$name" >&2
    diff -u "$left.stderr" "$right.stderr" >&2 || true
    failed=1
  fi
  (( failed == 0 ))
}

parity_outcome_suite() {
  local name=$1 file=$2
  local exe="$BL_TEST_ROOT/build/${name}-test"
  local interpreted="$BL_TEST_ROOT/build/${name}-interpreted"
  local compiled="$BL_TEST_ROOT/build/${name}-compiled"
  local outcomes_equal=1

  "$BL_TEST_ROOT/blisp" compile "$BL_TEST_ROOT/$file" -o "$exe" >/dev/null
  capture_outcome "$interpreted" "$BL_TEST_ROOT/blisp" run "$BL_TEST_ROOT/$file"
  capture_outcome "$compiled" "$exe"
  compare_outcomes "$name" "$interpreted" "$compiled" || outcomes_equal=0

  BL_PARITY_STATUS=$(<"$interpreted.status")
  BL_PARITY_STDOUT="$interpreted.stdout"
  BL_PARITY_STDERR="$interpreted.stderr"
  BL_PARITY_COMPILED_STATUS=$(<"$compiled.status")
  BL_PARITY_COMPILED_STDOUT="$compiled.stdout"
  BL_PARITY_COMPILED_STDERR="$compiled.stderr"

  (( outcomes_equal ))
}

show_outcome_file() {
  local label=$1 path=$2
  [[ -s $path ]] || return 0
  printf '%s\n' "--- $label ---" >&2
  cat "$path" >&2 || true
}

parity_suite() {
  local name=$1 file=$2
  parity_outcome_suite "$name" "$file" || return
  if (( BL_PARITY_STATUS != 0 )); then
    printf 'expected successful outcome in %s, got status %d\n' "$name" "$BL_PARITY_STATUS" >&2
    show_outcome_file 'captured stdout' "$BL_PARITY_STDOUT"
    show_outcome_file 'captured stderr' "$BL_PARITY_STDERR"
    return 1
  fi
  cat "$BL_PARITY_STDOUT"
  printf '%s\n' "$name interpreter/compiler outcome identical"
}

parity_failure_suite() {
  local name=$1 file=$2
  parity_outcome_suite "$name" "$file" || return
  if (( BL_PARITY_STATUS == 0 )); then
    printf 'expected failing outcome in %s, got success\n' "$name" >&2
    show_outcome_file 'captured stdout' "$BL_PARITY_STDOUT"
    show_outcome_file 'captured stderr' "$BL_PARITY_STDERR"
    return 1
  fi
  printf '%s: matching failure status=%d\n' "$name" "$BL_PARITY_STATUS"
}
