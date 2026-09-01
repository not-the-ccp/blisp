#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/explicit.blx" <<'EOF'
let ok = 1;
let broken = (1 + );
EOF
if ./blisp run "$tmp/explicit.blx" >"$tmp/out" 2>"$tmp/err"; then
  echo 'diagnostics: expected explicit parse failure' >&2; exit 1
fi
grep -F "$tmp/explicit.blx:2:" "$tmp/err" >/dev/null
grep -F 'let broken = (1 + );' "$tmp/err" >/dev/null
grep -F '^' "$tmp/err" >/dev/null

cat > "$tmp/child.blx" <<'EOF'
let childOk = 1;
let childBroken = (2 * );
EOF
cat > "$tmp/main.blx" <<'EOF'
include "child.blx";
println("never");
EOF
if ./blisp run "$tmp/main.blx" >"$tmp/out" 2>"$tmp/err"; then
  echo 'diagnostics: expected included parse failure' >&2; exit 1
fi
grep -F "$tmp/child.blx:2:" "$tmp/err" >/dev/null

cat > "$tmp/after-include.blx" <<'EOF'
let before = 1;
include "good.blx";
let brokenAfter = (3 + );
EOF
cat > "$tmp/good.blx" <<'EOF'
let included = 2;
EOF
if ./blisp run "$tmp/after-include.blx" >"$tmp/out" 2>"$tmp/err"; then
  echo 'diagnostics: expected post-include parse failure' >&2; exit 1
fi
grep -F "$tmp/after-include.blx:3:" "$tmp/err" >/dev/null

cat > "$tmp/layout.blx" <<'EOF'
fn demo(x)
    if x > 0
        println(x)
    else
        let nope = (x + )

demo(1)
EOF
if ./blisp run "$tmp/layout.blx" >"$tmp/out" 2>"$tmp/err"; then
  echo 'diagnostics: expected layout parse failure' >&2; exit 1
fi
grep -F "$tmp/layout.blx:5:" "$tmp/err" >/dev/null
grep -F 'let nope = (x + )' "$tmp/err" >/dev/null

echo 'diagnostics: ok'
