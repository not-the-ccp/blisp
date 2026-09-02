#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

out=build/web-build-output
rm -rf -- "$out"

result=$(./blisp web build tests/web-build.blx -o "$out")
[[ $result == "$out" ]]
[[ -f $out/index.html ]]
[[ -f $out/assets/app.css ]]

grep -Fq '<title>Build fixture</title>' "$out/index.html"
grep -Fq '<h1>Static BLisp build</h1>' "$out/index.html"
grep -Fq 'href="assets/app.css"' "$out/index.html"
[[ $(cat "$out/assets/app.css") == 'body{font-family:system-ui;margin:0;}.card{padding:1rem;}' ]]

# Refuse to mix a fresh deterministic build with stale output.
if ./blisp web build tests/web-build.blx -o "$out" >build/web-build-repeat.out 2>build/web-build-repeat.err; then
  echo 'web build unexpectedly accepted a non-empty output directory' >&2
  exit 1
fi
grep -Fq 'output directory is not empty' build/web-build-repeat.err

printf 'web build: ok\n'
