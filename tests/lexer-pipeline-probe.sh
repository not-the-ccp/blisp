#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

source runtime.sh
source compiler.sh
source surface.sh
source layout.sh

fixture=tests/lexer-pipeline-repro.blx
src=$(cat -- "$fixture")

# The raw surface lexer and its layout-aware wrapper must agree that the exact
# same source is valid before the CLI source-loader/compiler paths see it.
sx_lex_without_layout "$src"
sx_lex "$src"

./blisp check "$fixture" >/dev/null
./blisp run "$fixture" >build/lexer-pipeline-run.out
./blisp compile "$fixture" -o build/lexer-pipeline-repro
build/lexer-pipeline-repro >build/lexer-pipeline-compiled.out

cmp build/lexer-pipeline-run.out build/lexer-pipeline-compiled.out
expected=$'red;\nx}body\nlast string in nested callback\n'
actual=$(cat build/lexer-pipeline-run.out; printf x)
actual=${actual%x}
[[ $actual == "$expected" ]]

printf 'lexer pipeline: ok\n'
