#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source tests/differential-lib.sh

printf '%s\n' '[fast 1/4] shell syntax + include loader'
bash -n blisp runtime.sh compiler.sh surface.sh layout.sh tests/*.sh
bash tests/includes.sh
bash tests/diagnostics.sh

printf '%s\n' '[fast 2/4] focused interpreter/compiler suites (isolated, parallel)'
suites=(operators ranges hygiene environment hashability callables grammar layout ergonomics string-nul web-html web-css web-static)
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

printf '%s\n' '[fast 3/4] structured failures + generated semantic combinations'
bash tests/outcomes.sh
bash tests/generated-differential.sh

printf '%s\n' '[fast 4/4] complete'
printf '%s\n' 'FAST DIFFERENTIAL SUITE PASSED'
