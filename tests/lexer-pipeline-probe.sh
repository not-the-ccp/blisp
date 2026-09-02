#!/usr/bin/env bash
set -u
cd -- "$(dirname -- "$0")/.."

source runtime.sh
source compiler.sh
source surface.sh
source layout.sh

fixture=tests/lexer-pipeline-repro.blx
bl_runtime_init
BL_SOURCE_CHUNKS=()
BL_SOURCE_CHUNK_FILES=()
BL_SOURCE_CHUNK_LINES=()
BL_INCLUDE_ACTIVE=()
BL_INCLUDE_SEEN=()
bl_collect_hybrid_file "$fixture" || exit 1

printf 'chunks=%d\n' "${#BL_SOURCE_CHUNKS[@]}"
for ((i=0; i<${#BL_SOURCE_CHUNKS[@]}; i++)); do
  chunk=${BL_SOURCE_CHUNKS[i]}
  file=${BL_SOURCE_CHUNK_FILES[i]}
  line=${BL_SOURCE_CHUNK_LINES[i]}
  printf 'chunk[%d] file=%s line=%s bytes=%d layout=' "$i" "$file" "$line" "${#chunk}"
  if sx_layout_maybe_needed "$chunk"; then printf 'yes\n'; else printf 'no\n'; fi

  sx_lex_without_layout "$chunk" >/dev/null 2>build/lexer-direct.err
  direct=$?
  sx_lex "$chunk" >/dev/null 2>build/lexer-wrapped.err
  wrapped=$?
  printf '  direct=%d wrapped=%d\n' "$direct" "$wrapped"
  if (( direct != 0 )); then sed 's/^/  direct: /' build/lexer-direct.err; fi
  if (( wrapped != 0 )); then sed 's/^/  wrapped: /' build/lexer-wrapped.err; fi
done

set +e
./blisp check "$fixture" >build/lexer-check.out 2>build/lexer-check.err
check_status=$?
set -e
printf 'blisp-check=%d\n' "$check_status"
sed 's/^/  check: /' build/lexer-check.err

# Deliberately fail while this is a diagnostic probe so CI preserves the output.
exit 1
