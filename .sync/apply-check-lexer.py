from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected one match, found {n}: {old[:100]!r}")
    p.write_text(s.replace(old, new, 1))

# A wrapper may lex synthetic layout source while diagnostics refer to the original.
replace_once("surface.sh", "SX_SOURCE_LINE_BASE=1\n", "SX_SOURCE_LINE_BASE=1\nSX_LEX_KEEP_SOURCE_CONTEXT=0\n")

# Factor a general source diagnostic renderer out of parser errors.
old = '''sx_error() {\n  local near='<eof>'\n  (( SX_POS < ${#SX_TOK_VAL[@]} )) && near=${SX_TOK_VAL[SX_POS]}\n  local off=${SX_TOK_OFF[SX_POS]-${#SX_SOURCE_TEXT}} line col excerpt\n  sx_error_location "$off"\n  line=$SX_ERROR_LINE; col=$SX_ERROR_COL\n  local display_line=$((line + SX_SOURCE_LINE_BASE - 1))\n  sx_source_line "$SX_SOURCE_TEXT" "$line"; excerpt=$SX_ERROR_EXCERPT\n  printf '%s:%d:%d: BLisp hybrid parse error: %s (near %q)\\n' "$SX_SOURCE_NAME" "$display_line" "$col" "$*" "$near" >&2\n  [[ -n $excerpt ]] && {\n    printf '  %s\\n' "$excerpt" >&2\n    printf '  %*s^\\n' "$((col-1))" '' >&2\n  }\n  return 1\n}\n'''
new = '''sx_diagnostic_at() {\n  local off=$1 kind=$2 message=$3 suffix=${4:-} line col excerpt\n  sx_error_location "$off"\n  line=$SX_ERROR_LINE; col=$SX_ERROR_COL\n  local display_line=$((line + SX_SOURCE_LINE_BASE - 1))\n  sx_source_line "$SX_SOURCE_TEXT" "$line"; excerpt=$SX_ERROR_EXCERPT\n  printf '%s:%d:%d: BLisp hybrid %s: %s%s\\n' "$SX_SOURCE_NAME" "$display_line" "$col" "$kind" "$message" "$suffix" >&2\n  [[ -n $excerpt ]] && {\n    printf '  %s\\n' "$excerpt" >&2\n    printf '  %*s^\\n' "$((col-1))" '' >&2\n  }\n  return 1\n}\n\nsx_error() {\n  local near='<eof>'\n  (( SX_POS < ${#SX_TOK_VAL[@]} )) && near=${SX_TOK_VAL[SX_POS]}\n  local off=${SX_TOK_OFF[SX_POS]-${#SX_SOURCE_TEXT}}\n  sx_diagnostic_at "$off" 'parse error' "$*" " (near $(printf '%q' "$near"))"\n}\n\nsx_lex_error() { sx_diagnostic_at "${2:-$SX_TOKEN_OFFSET}" 'lexer error' "$1"; }\n'''
replace_once("surface.sh", old, new)

# Preserve source context when invoked by the layout wrapper.
replace_once(
    "surface.sh",
    '''  SX_SOURCE_TEXT=$src; SX_LAYOUT_DIAG_ACTIVE=0; SX_LAYOUT_LEX_SOURCE=\n  SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_TOK_OFF=(); SX_POS=0\n  while (( i < n )); do\n    c=${src:i:1}\n''',
    '''  if (( ! SX_LEX_KEEP_SOURCE_CONTEXT )); then\n    SX_SOURCE_TEXT=$src; SX_LAYOUT_DIAG_ACTIVE=0; SX_LAYOUT_LEX_SOURCE=\n  fi\n  SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_TOK_OFF=(); SX_POS=0\n  while (( i < n )); do\n    c=${src:i:1}\n''',
)
# Offset should be established before comment lexing too.
replace_once(
    "surface.sh",
    '''    case $c in\n      ' '|$'\\t'|$'\\r'|$'\\n') gap=1; ((i++)) || true; continue ;;\n    esac\n    if [[ $c == / && ${src:i+1:1} == / ]]; then\n''',
    '''    case $c in\n      ' '|$'\\t'|$'\\r'|$'\\n') gap=1; ((i++)) || true; continue ;;\n    esac\n    SX_TOKEN_OFFSET=$i\n    if [[ $c == / && ${src:i+1:1} == / ]]; then\n''',
)
# Remove now-redundant assignment before normal tokens.
replace_once("surface.sh", "    SX_TOKEN_OFFSET=$i\n    if [[ $c == b &&", "    if [[ $c == b &&")

repls = {
"      ((i+1<n)) || { echo 'BLisp hybrid: unterminated block comment' >&2; return 1; }": "      ((i+1<n)) || { sx_lex_error 'unterminated block comment'; return 1; }",
"          ((i<n)) || { echo 'BLisp hybrid: unterminated byte escape' >&2; return 1; }": "          ((i<n)) || { sx_lex_error 'unterminated byte escape'; return 1; }",
"              ((i+1<n)) || { echo 'BLisp hybrid: short \\\\x escape' >&2; return 1; }": "              ((i+1<n)) || { sx_lex_error 'short \\\\x escape'; return 1; }",
"              h1=${src:i:1}; h2=${src:i+1:1}; [[ $h1$h2 =~ ^[0-9A-Fa-f]{2}$ ]] || { echo 'BLisp hybrid: invalid \\\\x escape' >&2; return 1; }": "              h1=${src:i:1}; h2=${src:i+1:1}; [[ $h1$h2 =~ ^[0-9A-Fa-f]{2}$ ]] || { sx_lex_error 'invalid \\\\x escape'; return 1; }",
"            *) printf 'BLisp hybrid: unsupported byte escape \\\\%s\\n' \"$esc\" >&2; return 1;;": "            *) sx_lex_error \"unsupported byte escape \\\\$esc\"; return 1;;",
"          ((ord>=0 && ord<=127)) || { echo 'BLisp hybrid: non-ASCII byte literal text must use \\\\xHH' >&2; return 1; }": "          ((ord>=0 && ord<=127)) || { sx_lex_error 'non-ASCII byte literal text must use \\\\xHH'; return 1; }",
"      [[ $c == \"$q\" ]] || { echo 'BLisp hybrid: unterminated byte literal' >&2; return 1; }": "      [[ $c == \"$q\" ]] || { sx_lex_error 'unterminated byte literal'; return 1; }",
"          ((i<n)) || { echo 'BLisp hybrid: unterminated string escape' >&2; return 1; }": "          ((i<n)) || { sx_lex_error 'unterminated string escape'; return 1; }",
"            0) echo 'BLisp hybrid: Bash strings cannot contain NUL bytes' >&2; return 1;;": "            0) sx_lex_error 'this reference implementation cannot store NUL in strings; use bytes'; return 1;;",
"      [[ $c == \"$q\" ]] || { echo 'BLisp hybrid: unterminated string' >&2; return 1; }": "      [[ $c == \"$q\" ]] || { sx_lex_error 'unterminated string'; return 1; }",
"      *) printf 'BLisp hybrid lexer: unexpected character %q\\n' \"$c\" >&2; return 1 ;;": "      *) sx_lex_error \"unexpected character $(printf '%q' \"$c\")\"; return 1 ;;",
}
for old_s, new_s in repls.items():
    replace_once("surface.sh", old_s, new_s)

# Make layout lexer establish source mapping before the underlying lexer can fail.
replace_once(
    "layout.sh",
    '''  local original_source=$1\n  sx_layout_rewrite_source "$1" || return\n  sx_lex_without_layout "$SX_LAYOUT_REWRITTEN" || return\n  SX_LAYOUT_DIAG_ACTIVE=1\n  SX_LAYOUT_LEX_SOURCE=$SX_LAYOUT_REWRITTEN\n  SX_SOURCE_TEXT=$original_source\n  local i\n''',
    '''  local original_source=$1 st\n  sx_layout_rewrite_source "$1" || return\n  SX_LAYOUT_DIAG_ACTIVE=1\n  SX_LAYOUT_LEX_SOURCE=$SX_LAYOUT_REWRITTEN\n  SX_SOURCE_TEXT=$original_source\n  SX_LEX_KEEP_SOURCE_CONTEXT=1\n  sx_lex_without_layout "$SX_LAYOUT_REWRITTEN"; st=$?\n  SX_LEX_KEEP_SOURCE_CONTEXT=0\n  (( st == 0 )) || return "$st"\n  local i\n''',
)

# Add parse-only check command.
replace_once(
    "blisp",
    '''  blisp run FILE [args...]         # .bl = classic Lisp syntax, .blx/.blh = hybrid syntax\n  blisp eval EXPR\n''',
    '''  blisp run FILE [args...]         # .bl = classic Lisp syntax, .blx/.blh = hybrid syntax\n  blisp check FILE                       # parse source/include graph without executing it\n  blisp eval EXPR\n''',
)
insert_before = '''cmd_eval() {\n'''
check_fn = '''cmd_check() {\n  (($# == 1)) || { usage >&2; return 2; }\n  local file=$1 src\n  [[ -f $file ]] || { echo "blisp: no such file: $file" >&2; return 2; }\n  bl_runtime_init\n  if is_surface_file "$file"; then\n    BL_SOURCE_CHUNKS=(); BL_SOURCE_CHUNK_FILES=(); BL_SOURCE_CHUNK_LINES=(); BL_INCLUDE_ACTIVE=(); BL_INCLUDE_SEEN=()\n    bl_collect_hybrid_file "$file" || return\n    bl_parse_surface_chunks || return\n  else\n    src=$(cat -- "$file") || return\n    bl_parse_all "$src" || return\n  fi\n  printf 'ok\\n'\n}\n\n'''
replace_once("blisp", insert_before, check_fn + insert_before)
replace_once("blisp", "    run) cmd_run \"$@\" ;;\n    eval)", "    run) cmd_run \"$@\" ;;\n    check) cmd_check \"$@\" ;;\n    eval)")

# Expand diagnostics regression coverage.
p = Path("tests/diagnostics.sh")
s = p.read_text()
needle = "echo 'diagnostics: ok'\n"
addition = r'''cat > "$tmp/lex.blx" <<'EOF'
let x = "unterminated
EOF
if ./blisp check "$tmp/lex.blx" >"$tmp/out" 2>"$tmp/err"; then
  echo 'diagnostics: expected lexer failure' >&2; exit 1
fi
grep -F "$tmp/lex.blx:1:" "$tmp/err" >/dev/null
grep -F 'lexer error: unterminated string' "$tmp/err" >/dev/null
grep -F 'let x = "unterminated' "$tmp/err" >/dev/null

cat > "$tmp/noexec.blx" <<'EOF'
fn valid(x) { return x + 1; }
error("check must not execute this");
EOF
[[ $(./blisp check "$tmp/noexec.blx") == ok ]]

cat > "$tmp/layout-lex.blx" <<'EOF'
fn f()
    println("unterminated)
EOF
if ./blisp check "$tmp/layout-lex.blx" >"$tmp/out" 2>"$tmp/err"; then
  echo 'diagnostics: expected layout lexer failure' >&2; exit 1
fi
grep -F "$tmp/layout-lex.blx:2:" "$tmp/err" >/dev/null

echo 'diagnostics: ok'
'''
if s.count(needle) != 1:
    raise SystemExit("tests/diagnostics.sh: final marker not unique")
p.write_text(s.replace(needle, addition))
