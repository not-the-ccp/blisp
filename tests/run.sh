#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
bash tests/fast.sh
bash tests/stdlib-parity.sh
