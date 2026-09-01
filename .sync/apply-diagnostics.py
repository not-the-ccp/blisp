from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:80]!r}")
    p.write_text(s.replace(old, new, 1))

# surface.sh: token offsets and source-aware diagnostics.
replace_once(
    "surface.sh",
    'declare -ag SX_TOK_TYPE=() SX_TOK_VAL=() SX_TOK_GAP=()\n',
    'declare -ag SX_TOK_TYPE=() SX_TOK_VAL=() SX_TOK_GAP=() SX_TOK_OFF=()\n',
)
replace_once(
    "surface.sh",
    'SX_ARROW_SUPPRESS_POS=-1\n',
    '''SX_ARROW_SUPPRESS_POS=-1\nSX_SOURCE_NAME='<input>'\nSX_SOURCE_TEXT=\nSX_TOKEN_OFFSET=0\nSX_LAYOUT_DIAG_ACTIVE=0\nSX_LAYOUT_LEX_SOURCE=\nSX_SOURCE_LINE_BASE=1\n''',
)
replace_once(
    "surface.sh",
    '''sx_error() {\n  local near='<eof>'\n  (( SX_POS < ${#SX_TOK_VAL[@]} )) && near=${SX_TOK_VAL[SX_POS]}\n  printf 'BLisp hybrid parse error near token %d (%q): %s\\n' "$SX_POS" "$near" "$*" >&2\n  return 1\n}\n\nsx_tok() {\n  SX_TOK_TYPE+=("$1"); SX_TOK_VAL+=("$2"); SX_TOK_GAP+=("$3")\n}\n''',
    '''sx_error() {\n  local near='<eof>'\n  (( SX_POS < ${#SX_TOK_VAL[@]} )) && near=${SX_TOK_VAL[SX_POS]}\n  local off=${SX_TOK_OFF[SX_POS]-${#SX_SOURCE_TEXT}} line col excerpt\n  sx_error_location "$off"\n  line=$SX_ERROR_LINE; col=$SX_ERROR_COL\n  local display_line=$((line + SX_SOURCE_LINE_BASE - 1))\n  sx_source_line "$SX_SOURCE_TEXT" "$line"; excerpt=$SX_ERROR_EXCERPT\n  printf '%s:%d:%d: BLisp hybrid parse error: %s (near %q)\\n' "$SX_SOURCE_NAME" "$display_line" "$col" "$*" "$near" >&2\n  [[ -n $excerpt ]] && {\n    printf '  %s\\n' "$excerpt" >&2\n    printf '  %*s^\\n' "$((col-1))" '' >&2\n  }\n  return 1\n}\n\nSX_ERROR_LINE=1\nSX_ERROR_COL=1\nSX_ERROR_EXCERPT=\nsx_line_col_in_source() {\n  local src=$1 off=$2 prefix line=1\n  (( off < 0 )) && off=0\n  (( off > ${#src} )) && off=${#src}\n  prefix=${src:0:off}\n  while [[ $prefix == *$'\\n'* ]]; do prefix=${prefix#*$'\\n'}; ((line++)) || true; done\n  SX_ERROR_LINE=$line\n  SX_ERROR_COL=$((${#prefix}+1))\n}\n\nsx_source_line() {\n  local src=$1 want=$2 line n=1\n  SX_ERROR_EXCERPT=\n  while IFS= read -r line || [[ -n $line ]]; do\n    if (( n == want )); then SX_ERROR_EXCERPT=$line; return 0; fi\n    ((n++)) || true\n  done <<< "$src"\n}\n\nsx_error_location() {\n  local off=$1\n  if (( SX_LAYOUT_DIAG_ACTIVE )); then\n    sx_line_col_in_source "$SX_LAYOUT_LEX_SOURCE" "$off"\n    local rewritten_line=$SX_ERROR_LINE rewritten_col=$SX_ERROR_COL line n=0 i=0 is_marker=0\n    while IFS= read -r line || [[ -n $line ]]; do\n      ((i++)) || true\n      is_marker=0\n      [[ $line == *"$SX_LAYOUT_M_NL"* || $line == *"$SX_LAYOUT_M_INDENT"* || $line == *"$SX_LAYOUT_M_DEDENT"* ]] && is_marker=1\n      (( ! is_marker )) && ((n++)) || true\n      if (( i == rewritten_line )); then\n        if (( is_marker )); then SX_ERROR_LINE=$((n+1)); SX_ERROR_COL=1\n        else SX_ERROR_LINE=$n; SX_ERROR_COL=$rewritten_col\n        fi\n        return\n      fi\n    done <<< "$SX_LAYOUT_LEX_SOURCE"\n    SX_ERROR_LINE=$((n+1)); SX_ERROR_COL=1\n    return\n  fi\n  sx_line_col_in_source "$SX_SOURCE_TEXT" "$off"\n}\n\nsx_tok() {\n  SX_TOK_TYPE+=("$1"); SX_TOK_VAL+=("$2"); SX_TOK_GAP+=("$3"); SX_TOK_OFF+=("$SX_TOKEN_OFFSET")\n}\n''',
)
replace_once(
    "surface.sh",
    '''sx_lex() {\n  local src=$1 i=0 n=${#1} c d q buf esc op gap=1\n  SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_POS=0\n''',
    '''sx_lex() {\n  local src=$1 i=0 n=${#1} c d q buf esc op gap=1\n  SX_SOURCE_TEXT=$src; SX_LAYOUT_DIAG_ACTIVE=0; SX_LAYOUT_LEX_SOURCE=\n  SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_TOK_OFF=(); SX_POS=0\n''',
)
replace_once(
    "surface.sh",
    '''      ((i+=2)) || true; continue\n    fi\n    if [[ $c == b && ( ${src:i+1:1} == '\"' || ${src:i+1:1} == "'" ) ]]; then\n''',
    '''      ((i+=2)) || true; continue\n    fi\n    SX_TOKEN_OFFSET=$i\n    if [[ $c == b && ( ${src:i+1:1} == '\"' || ${src:i+1:1} == "'" ) ]]; then\n''',
)
replace_once(
    "surface.sh",
    '''  done\n  sx_tok eof '<eof>' 1\n}\n\nsx_is()''',
    '''  done\n  SX_TOKEN_OFFSET=$n\n  sx_tok eof '<eof>' 1\n}\n\nsx_is()''',
)
replace_once(
    "surface.sh",
    '''bl_parse_surface_all() {\n  local src=$1\n  sx_lex "$src" || return\n''',
    '''bl_parse_surface_all() {\n  local src=$1 source_name=${2:-${SX_SOURCE_NAME:-'<input>'}} line_base=${3:-1}\n  SX_SOURCE_NAME=$source_name; SX_SOURCE_LINE_BASE=$line_base\n  sx_lex "$src" || return\n''',
)
replace_once(
    "surface.sh",
    '''bl_interpret_surface_source() {\n  local src=$1 env=${2:-$BL_GLOBAL_ENV} form\n  bl_parse_surface_all "$src" || return\n''',
    '''bl_interpret_surface_source() {\n  local src=$1 env=${2:-$BL_GLOBAL_ENV} source_name=${3:-${SX_SOURCE_NAME:-'<input>'}} line_base=${4:-1} form\n  bl_parse_surface_all "$src" "$source_name" "$line_base" || return\n''',
)

# layout.sh: preserve original physical source while lexing the synthetic stream.
replace_once(
    "layout.sh",
    '''sx_lex() {\n  if ! sx_layout_maybe_needed "$1"; then\n    sx_lex_without_layout "$1"\n    return\n  fi\n  sx_layout_rewrite_source "$1" || return\n  sx_lex_without_layout "$SX_LAYOUT_REWRITTEN" || return\n  local i\n''',
    '''sx_lex() {\n  if ! sx_layout_maybe_needed "$1"; then\n    sx_lex_without_layout "$1"\n    return\n  fi\n  local original_source=$1\n  sx_layout_rewrite_source "$1" || return\n  sx_lex_without_layout "$SX_LAYOUT_REWRITTEN" || return\n  SX_LAYOUT_DIAG_ACTIVE=1\n  SX_LAYOUT_LEX_SOURCE=$SX_LAYOUT_REWRITTEN\n  SX_SOURCE_TEXT=$original_source\n  local i\n''',
)

# blisp: keep source chunk filename + starting physical line through includes.
replace_once(
    "blisp",
    'declare -ag BL_SOURCE_CHUNKS=() BL_SOURCE_CHUNK_FILES=()\n',
    'declare -ag BL_SOURCE_CHUNKS=() BL_SOURCE_CHUNK_FILES=() BL_SOURCE_CHUNK_LINES=()\n',
)
replace_once(
    "blisp",
    '''bl_source_chunk_add() {\n  local file=$1 text=$2\n  [[ -z $text ]] && return 0\n  BL_SOURCE_CHUNKS+=("$text")\n  BL_SOURCE_CHUNK_FILES+=("$file")\n}\n''',
    '''bl_source_chunk_add() {\n  local file=$1 text=$2 line=${3:-1}\n  [[ -z $text ]] && return 0\n  BL_SOURCE_CHUNKS+=("$text")\n  BL_SOURCE_CHUNK_FILES+=("$file")\n  BL_SOURCE_CHUNK_LINES+=("$line")\n}\n''',
)
replace_once(
    "blisp",
    '  local file=$1 abs dir line child buf= depth=0 quote= block=0 indent trimmed st\n',
    '  local file=$1 abs dir line child buf= depth=0 quote= block=0 indent trimmed st lineno=0 buf_start=1\n',
)
replace_once(
    "blisp",
    '''  while IFS= read -r line || [[ -n $line ]]; do\n    trimmed=${line#"${line%%[![:space:]]*}"}\n''',
    '''  while IFS= read -r line || [[ -n $line ]]; do\n    ((lineno++)) || true\n    trimmed=${line#"${line%%[![:space:]]*}"}\n''',
)
replace_once(
    "blisp",
    '''        bl_source_chunk_add "$abs" "$buf"; buf=\n        child=$BL_INCLUDE_PATH; [[ $child == /* ]] || child="$dir/$child"\n        bl_collect_hybrid_file "$child" || { unset 'BL_INCLUDE_ACTIVE[$abs]'; return 1; }\n        continue\n''',
    '''        bl_source_chunk_add "$abs" "$buf" "$buf_start"; buf=\n        child=$BL_INCLUDE_PATH; [[ $child == /* ]] || child="$dir/$child"\n        bl_collect_hybrid_file "$child" || { unset 'BL_INCLUDE_ACTIVE[$abs]'; return 1; }\n        buf_start=$((lineno+1))\n        continue\n''',
)
replace_once("blisp", '  bl_source_chunk_add "$abs" "$buf"\n', '  bl_source_chunk_add "$abs" "$buf" "$buf_start"\n')
replace_once(
    "blisp",
    '''  BL_SOURCE_CHUNKS=(); BL_SOURCE_CHUNK_FILES=(); BL_INCLUDE_ACTIVE=(); BL_INCLUDE_SEEN=()\n''',
    '''  BL_SOURCE_CHUNKS=(); BL_SOURCE_CHUNK_FILES=(); BL_SOURCE_CHUNK_LINES=(); BL_INCLUDE_ACTIVE=(); BL_INCLUDE_SEEN=()\n''',
)
replace_once(
    "blisp",
    '''bl_parse_surface_chunks() {\n  local -a all=() chunk\n  for chunk in "${BL_SOURCE_CHUNKS[@]}"; do\n    [[ -z ${chunk//[[:space:]]/} ]] && continue\n    bl_parse_surface_all "$chunk" || return\n    all+=("${BL_FORMS[@]}")\n  done\n  BL_FORMS=("${all[@]}")\n}\n''',
    '''bl_parse_surface_chunks() {\n  local -a all=(); local chunk file line_base i\n  for ((i=0;i<${#BL_SOURCE_CHUNKS[@]};++i)); do\n    chunk=${BL_SOURCE_CHUNKS[i]}; file=${BL_SOURCE_CHUNK_FILES[i]}; line_base=${BL_SOURCE_CHUNK_LINES[i]:-1}\n    [[ -z ${chunk//[[:space:]]/} ]] && continue\n    bl_parse_surface_all "$chunk" "$file" "$line_base" || return\n    all+=("${BL_FORMS[@]}")\n  done\n  BL_FORMS=("${all[@]}")\n}\n''',
)
replace_once(
    "blisp",
    '''bl_interpret_surface_chunks() {\n  local env=$1 chunk\n  RET=nil\n  for chunk in "${BL_SOURCE_CHUNKS[@]}"; do\n    [[ -z ${chunk//[[:space:]]/} ]] && continue\n    bl_interpret_surface_source "$chunk" "$env" || return\n  done\n}\n''',
    '''bl_interpret_surface_chunks() {\n  local env=$1 chunk file line_base i\n  RET=nil\n  for ((i=0;i<${#BL_SOURCE_CHUNKS[@]};++i)); do\n    chunk=${BL_SOURCE_CHUNKS[i]}; file=${BL_SOURCE_CHUNK_FILES[i]}; line_base=${BL_SOURCE_CHUNK_LINES[i]:-1}\n    [[ -z ${chunk//[[:space:]]/} ]] && continue\n    bl_interpret_surface_source "$chunk" "$env" "$file" "$line_base" || return\n  done\n}\n''',
)
# There are two command paths that reset source chunks.
s = Path("blisp").read_text()
old = 'BL_SOURCE_CHUNKS=(); BL_SOURCE_CHUNK_FILES=(); BL_INCLUDE_ACTIVE=(); BL_INCLUDE_SEEN=(); bl_collect_hybrid_file "$file" || return'
if s.count(old) != 2:
    raise SystemExit(f"blisp: expected two command chunk resets, found {s.count(old)}")
s = s.replace(old, 'BL_SOURCE_CHUNKS=(); BL_SOURCE_CHUNK_FILES=(); BL_SOURCE_CHUNK_LINES=(); BL_INCLUDE_ACTIVE=(); BL_INCLUDE_SEEN=(); bl_collect_hybrid_file "$file" || return')
Path("blisp").write_text(s)
replace_once(
    "blisp",
    '  bl_interpret_surface_source "$1" "$BL_GLOBAL_ENV" || return\n',
    '  bl_interpret_surface_source "$1" "$BL_GLOBAL_ENV" \'<evalx>\' || return\n',
)
replace_once(
    "blisp",
    '    if bl_interpret_surface_source "$line" "$BL_GLOBAL_ENV"; then bl_repr "$RET"; printf \'\\n\'; fi\n',
    '    if bl_interpret_surface_source "$line" "$BL_GLOBAL_ENV" \'<replx>\'; then bl_repr "$RET"; printf \'\\n\'; fi\n',
)

# Permanent regression tests.
replace_once(
    "tests/fast.sh",
    'bash tests/includes.sh\n',
    'bash tests/includes.sh\nbash tests/diagnostics.sh\n',
)
Path("tests/diagnostics.sh").write_text(r'''#!/usr/bin/env bash
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
''')
