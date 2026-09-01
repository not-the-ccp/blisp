#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source tests/differential-lib.sh
printf '%s\n' '[slow] standard-library differential suite'
parity_suite stdlib tests/stdlib.blx
printf '%s\n' 'STDLIB DIFFERENTIAL SUITE PASSED'
