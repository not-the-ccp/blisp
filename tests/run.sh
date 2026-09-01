#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

printf '%s\n' '[1/3] shell syntax'
bash -n blisp runtime.sh compiler.sh surface.sh

printf '%s\n' '[2/3] interpreted stdlib suite'
./blisp run tests/stdlib.blx

printf '%s\n' '[3/3] compiler parity'
mkdir -p build
./blisp compile tests/stdlib.blx -o build/stdlib-test
./build/stdlib-test > build/compiled-test.out
./blisp run tests/stdlib.blx > build/interpreted-test.out
cmp build/interpreted-test.out build/compiled-test.out
printf '%s\n' 'interpreter/compiler output identical'
