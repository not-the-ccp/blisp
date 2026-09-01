#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
mkdir -p build

printf '%s\n' '[1/5] shell syntax'
bash -n blisp runtime.sh compiler.sh surface.sh layout.sh

printf '%s\n' '[2/5] focused ergonomics + layout suites'
./blisp run tests/ergonomics.blx
./blisp run tests/layout.blx

printf '%s\n' '[3/5] layout compiler parity'
./blisp run tests/layout.blx > build/layout-interpreted.out
./blisp compile tests/layout.blx -o build/layout-test >/dev/null
./build/layout-test > build/layout-compiled.out
cmp build/layout-interpreted.out build/layout-compiled.out
printf '%s\n' 'layout interpreter/compiler output identical'

printf '%s\n' '[4/5] interpreted stdlib suite'
./blisp run tests/stdlib.blx

printf '%s\n' '[5/5] stdlib compiler parity'
./blisp compile tests/stdlib.blx -o build/stdlib-test >/dev/null
./build/stdlib-test > build/stdlib-compiled.out
./blisp run tests/stdlib.blx > build/stdlib-interpreted.out
cmp build/stdlib-interpreted.out build/stdlib-compiled.out
printf '%s\n' 'stdlib interpreter/compiler output identical'
