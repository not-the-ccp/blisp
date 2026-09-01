#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source tests/differential-lib.sh

printf '%s\n' '[fast 1/3] shell syntax + include loader'
bash -n blisp runtime.sh compiler.sh surface.sh layout.sh tests/*.sh
bash tests/includes.sh

printf '%s\n' '[fast 2/3] focused interpreter/compiler suites (isolated, parallel)'
suites=(operators ranges hygiene environment hashability callables grammar layout ergonomics)
declare -A pids=()
for name in "${suites[@]}"; do
  (
    parity_suite "$name" "tests/$name.blx"
  ) > "build/fast-$name.log" 2>&1 &
  pids[$name]=$!
done

failed=0
for name in "${suites[@]}"; do
  if wait "${pids[$name]}"; then
    cat "build/fast-$name.log"
  else
    printf '\n--- %s failed ---\n' "$name" >&2
    cat "build/fast-$name.log" >&2 || true
    failed=1
  fi
done
(( failed == 0 )) || exit 1

printf '%s\n' '[fast 3/3] complete'
printf '%s\n' 'FAST DIFFERENTIAL SUITE PASSED'
