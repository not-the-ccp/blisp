#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source tests/differential-lib.sh

mkdir -p build/outcome-cases

cat > build/outcome-cases/explicit-error.blx <<'EOF'
println("before");
error("boom", 42);
EOF

cat > build/outcome-cases/arity-error.blx <<'EOF'
fn pair(a, b) { return [a, b]; }
pair(1);
EOF

cat > build/outcome-cases/unbound.blx <<'EOF'
fn outer() {
  return missingName + 1;
}
outer();
EOF

parity_failure_suite explicit-error build/outcome-cases/explicit-error.blx
parity_failure_suite arity-error build/outcome-cases/arity-error.blx
parity_failure_suite unbound build/outcome-cases/unbound.blx

printf '%s\n' 'STRUCTURED FAILURE OUTCOME PARITY PASSED'
