#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source tests/differential-lib.sh

run_group() {
  local n=$1
  printf '[stdlib %s/4] module-group differential suite\n' "$n"
  parity_suite "stdlib-$n" "tests/stdlib-$n.blx"
}

if (($#)); then
  (($# == 1)) || { echo 'usage: stdlib-parity.sh [GROUP]' >&2; exit 2; }
  [[ $1 =~ ^[1-4]$ ]] || { echo 'stdlib group must be 1..4' >&2; exit 2; }
  run_group "$1"
else
  for n in 1 2 3 4; do run_group "$n"; done
fi
