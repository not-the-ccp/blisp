from pathlib import Path


def rep(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != count:
        raise SystemExit(f"{path}: expected {count} matches, got {n}: {old[:120]!r}")
    p.write_text(s.replace(old, new, count))


# --- runtime: source IDs + side-table spans ---------------------------------
rep(
    "runtime.sh",
    """BL_FLOW=\nBL_FLOW_VALUE=nil\n\nbl_alloc() {\n""",
    """BL_FLOW=\nBL_FLOW_VALUE=nil\n\n# Source identity and parsed-node provenance are side tables, deliberately\n# separate from ordinary BLisp values.  Quoted/code-as-data values therefore\n# keep the same equality, hashing and printed representation whether or not a\n# parser happened to associate source metadata with their heap handles.\ndeclare -Ag BL_SOURCE_ID_BY_NAME=() BL_SOURCE_NAME=()\ndeclare -Ag BL_NODE_SOURCE=() BL_NODE_START_LINE=() BL_NODE_START_COL=()\ndeclare -Ag BL_NODE_END_LINE=() BL_NODE_END_COL=() BL_NODE_ORIGIN=()\nBL_SOURCE_SEQ=0\n\nbl_source_intern() {\n  local name=$1\n  if [[ -v 'BL_SOURCE_ID_BY_NAME[$name]' ]]; then RET=${BL_SOURCE_ID_BY_NAME[$name]}; return; fi\n  ((++BL_SOURCE_SEQ)) || true\n  local id=\"s$BL_SOURCE_SEQ\"\n  BL_SOURCE_ID_BY_NAME[$name]=$id; BL_SOURCE_NAME[$id]=$name; RET=$id\n}\n\n# Spans are half-open: start is the first source character belonging to the\n# node and end is the position immediately after the final character.\nbl_node_span_set() {\n  local v=$1 src=$2 sl=$3 sc=$4 el=$5 ec=$6\n  [[ $v =~ ^v[0-9]+$ ]] || return 0\n  BL_NODE_SOURCE[$v]=$src; BL_NODE_START_LINE[$v]=$sl; BL_NODE_START_COL[$v]=$sc\n  BL_NODE_END_LINE[$v]=$el; BL_NODE_END_COL[$v]=$ec\n}\nbl_node_origin_set() { local v=$1 origin=$2; [[ $v =~ ^v[0-9]+$ ]] || return 0; BL_NODE_ORIGIN[$v]=$origin; }\n\nbl_alloc() {\n""",
)

# Callable construction is a constructor, not a predicate.  Previously its
# last `[[ proto != nil ]] && ...` leaked status 1 while bootstrapping the first
# builtins; a caller using `set -e` could therefore abort runtime initialization.
rep(
    "runtime.sh",
    """bl_init_callable() {\n  local v=$1 type=$2\n  BL_TYPE[$v]=$type\n  [[ $BL_FUNCTION_PROTO != nil ]] && BL_PROTO[$v]=$BL_FUNCTION_PROTO\n}\n""",
    """bl_init_callable() {\n  local v=$1 type=$2\n  BL_TYPE[$v]=$type\n  [[ $BL_FUNCTION_PROTO == nil ]] || BL_PROTO[$v]=$BL_FUNCTION_PROTO\n  return 0\n}\n""",
)

# Runtime reinitialization must clear every heap side table before value IDs are
# reused.  In particular BL_STR_HEX used to survive a reset, so a fresh `vN`
# could inherit the canonical bytes of an unrelated old NUL-containing string.
rep(
    "runtime.sh",
    """  BL_PROP=(); BL_PROTO=(); BL_KEY_COUNT=(); BL_KEY_AT=(); BL_ARR_LEN=(); BL_BYTES_LEN=(); BL_BYTE_AT=()\n  BL_OBJECT_PROTO=nil; BL_ARRAY_PROTO=nil; BL_FUNCTION_PROTO=nil; BL_STRING_PROTO=nil; BL_BYTES_PROTO=nil; BL_TCP_PROTO=nil; BL_FILE_PROTO=nil\n""",
    """  BL_PROP=(); BL_PROTO=(); BL_KEY_COUNT=(); BL_KEY_AT=(); BL_ARR_LEN=(); BL_BYTES_LEN=(); BL_BYTE_AT=(); BL_STR_HEX=()\n  BL_SOURCE_ID_BY_NAME=(); BL_SOURCE_NAME=(); BL_SOURCE_SEQ=0\n  BL_NODE_SOURCE=(); BL_NODE_START_LINE=(); BL_NODE_START_COL=(); BL_NODE_END_LINE=(); BL_NODE_END_COL=(); BL_NODE_ORIGIN=()\n  BL_OBJECT_PROTO=nil; BL_ARRAY_PROTO=nil; BL_FUNCTION_PROTO=nil; BL_STRING_PROTO=nil; BL_BYTES_PROTO=nil; BL_TCP_PROTO=nil; BL_FILE_PROTO=nil; BL_PROCESS_HANDLE_PROTO=nil\n""",
)

# Metadata must neither accidentally keep AST values alive nor survive after a
# heap value has been collected.
rep(
    "runtime.sh",
    """local name decl x; local -a excluded=(BL_TYPE BL_A BL_B BL_C BL_PROP BL_PROTO BL_KEY_COUNT BL_KEY_AT BL_ARR_LEN BL_BYTES_LEN BL_BYTE_AT BL_STR_HEX BL_ENV_PARENT BL_ENV_BIND BL_ENV_CONST BL_GC_VMARK BL_GC_EMARK)\n""",
    """local name decl x; local -a excluded=(BL_TYPE BL_A BL_B BL_C BL_PROP BL_PROTO BL_KEY_COUNT BL_KEY_AT BL_ARR_LEN BL_BYTES_LEN BL_BYTE_AT BL_STR_HEX BL_ENV_PARENT BL_ENV_BIND BL_ENV_CONST BL_GC_VMARK BL_GC_EMARK BL_SOURCE_ID_BY_NAME BL_SOURCE_NAME BL_NODE_SOURCE BL_NODE_START_LINE BL_NODE_START_COL BL_NODE_END_LINE BL_NODE_END_COL BL_NODE_ORIGIN)\n""",
)
rep(
    "runtime.sh",
    """unset 'BL_TYPE[$v]' 'BL_A[$v]' 'BL_B[$v]' 'BL_C[$v]' 'BL_PROTO[$v]' 'BL_KEY_COUNT[$v]' 'BL_ARR_LEN[$v]' 'BL_BYTES_LEN[$v]' 'BL_STR_HEX[$v]'\n""",
    """unset 'BL_TYPE[$v]' 'BL_A[$v]' 'BL_B[$v]' 'BL_C[$v]' 'BL_PROTO[$v]' 'BL_KEY_COUNT[$v]' 'BL_ARR_LEN[$v]' 'BL_BYTES_LEN[$v]' 'BL_STR_HEX[$v]'\n    unset 'BL_NODE_SOURCE[$v]' 'BL_NODE_START_LINE[$v]' 'BL_NODE_START_COL[$v]' 'BL_NODE_END_LINE[$v]' 'BL_NODE_END_COL[$v]' 'BL_NODE_ORIGIN[$v]'\n""",
)

# --- hybrid lexer/parser: exact token ends and structural span wrappers -------
rep(
    "surface.sh",
    "declare -ag SX_TOK_TYPE=() SX_TOK_VAL=() SX_TOK_GAP=() SX_TOK_OFF=()\n",
    "declare -ag SX_TOK_TYPE=() SX_TOK_VAL=() SX_TOK_GAP=() SX_TOK_OFF=() SX_TOK_END=()\n",
)
rep(
    "surface.sh",
    "SX_SOURCE_NAME='<input>'\n",
    "SX_SOURCE_NAME='<input>'\nSX_SOURCE_ID=\n",
)
rep(
    "surface.sh",
    """sx_tok() {\n  SX_TOK_TYPE+=(\"$1\"); SX_TOK_VAL+=(\"$2\"); SX_TOK_GAP+=(\"$3\"); SX_TOK_OFF+=(\"$SX_TOKEN_OFFSET\")\n}\n""",
    """sx_tok() {\n  local end=${4:-$SX_TOKEN_OFFSET}\n  SX_TOK_TYPE+=(\"$1\"); SX_TOK_VAL+=(\"$2\"); SX_TOK_GAP+=(\"$3\"); SX_TOK_OFF+=(\"$SX_TOKEN_OFFSET\"); SX_TOK_END+=(\"$end\")\n}\n""",
)
rep(
    "surface.sh",
    "SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_TOK_OFF=(); SX_POS=0\n",
    "SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_TOK_OFF=(); SX_TOK_END=(); SX_POS=0\n",
)

# Each lexer branch already has i positioned immediately after its token except
# punctuation branches, whose exact end is stated explicitly here.
for old, new in [
    ('sx_tok bytes "$buf" "$gap"; gap=0; continue', 'sx_tok bytes "$buf" "$gap" "$i"; gap=0; continue'),
    ('sx_tok id "$buf" "$gap"; gap=0; continue', 'sx_tok id "$buf" "$gap" "$i"; gap=0; continue'),
    ('sx_tok num "$buf" "$gap"; gap=0; continue', 'sx_tok num "$buf" "$gap" "$i"; gap=0; continue'),
    ('sx_tok str "$buf" "$gap"; gap=0; continue', 'sx_tok str "$buf" "$gap" "$i"; gap=0; continue'),
    ('if [[ -n $op ]]; then sx_tok op "$op" "$gap"; gap=0; ((i+=${#op})) || true; continue; fi',
     'if [[ -n $op ]]; then sx_tok op "$op" "$gap" "$((i+${#op}))"; gap=0; ((i+=${#op})) || true; continue; fi'),
    ("if [[ ${src:i:2} == '..' ]]; then sx_tok op '..' \"$gap\"; gap=0; ((i+=2)) || true; continue; fi",
     "if [[ ${src:i:2} == '..' ]]; then sx_tok op '..' \"$gap\" \"$((i+2))\"; gap=0; ((i+=2)) || true; continue; fi"),
    ('sx_tok op "$c" "$gap"; gap=0; ((i++)) || true ;;', 'sx_tok op "$c" "$gap" "$((i+1))"; gap=0; ((i++)) || true ;;'),
    ("sx_tok eof '<eof>' 1", "sx_tok eof '<eof>' 1 \"$n\""),
]:
    rep("surface.sh", old, new)

# Convert token offsets to source-manager positions using the same layout-aware
# mapping already used by parser diagnostics.  This is structural metadata, not
# a rendered diagnostic string.
rep(
    "surface.sh",
    """sx_is() { [[ ${SX_TOK_VAL[SX_POS]-'<eof>'} == \"$1\" ]]; }\n""",
    """sx_mark_range() {\n  local v=$1 start_pos=$2 end_pos=$3\n  [[ $v =~ ^v[0-9]+$ && -n $SX_SOURCE_ID ]] || return 0\n  (( start_pos >= 0 && start_pos < ${#SX_TOK_OFF[@]} )) || return 0\n  local start=${SX_TOK_OFF[start_pos]} end=$start last\n  if (( end_pos > start_pos )); then\n    last=$((end_pos-1)); end=${SX_TOK_END[last]-${SX_TOK_OFF[last]}}\n  fi\n  sx_error_location \"$start\"\n  local sl=$((SX_ERROR_LINE + SX_SOURCE_LINE_BASE - 1)) sc=$SX_ERROR_COL\n  sx_error_location \"$end\"\n  local el=$((SX_ERROR_LINE + SX_SOURCE_LINE_BASE - 1)) ec=$SX_ERROR_COL\n  bl_node_span_set \"$v\" \"$SX_SOURCE_ID\" \"$sl\" \"$sc\" \"$el\" \"$ec\"\n}\n\nsx_is() { [[ ${SX_TOK_VAL[SX_POS]-'<eof>'} == \"$1\" ]]; }\n""",
)

# Assignment is the common expression boundary.  Keep the existing parser as an
# inner implementation so recursive calls continue through the provenance
# wrapper and nested expressions receive their own spans.
rep("surface.sh", "\nsx_parse_assignment() {\n", "\nsx_parse_assignment_inner() {\n")
rep(
    "surface.sh",
    "\n\nsx_parse_conditional() {\n",
    """\n\nsx_parse_assignment() {\n  local __start=$SX_POS\n  sx_parse_assignment_inner || return\n  local __v=$RET\n  sx_mark_range \"$__v\" \"$__start\" \"$SX_POS\"\n  RET=$__v\n}\n\nsx_parse_conditional() {\n""",
)

# Postfix is the call/property/index boundary.  Mark it independently so an
# inner call used as part of a larger expression keeps a precise call-site span.
rep(
    "surface.sh",
    """sx_parse_postfix() {\n  sx_parse_primary || return; sx_parse_postfix_tail \"$RET\"\n}\n""",
    """sx_parse_postfix() {\n  local __start=$SX_POS\n  sx_parse_primary || return\n  sx_parse_postfix_tail \"$RET\" || return\n  local __v=$RET\n  sx_mark_range \"$__v\" \"$__start\" \"$SX_POS\"\n  RET=$__v\n}\n""",
)

# Statement spans include their trailing semicolon when one is present.  This
# wrapper also covers lowered statement forms such as classes/destructuring.
rep("surface.sh", "\nsx_parse_statement() {\n", "\nsx_parse_statement_inner() {\n")
rep(
    "surface.sh",
    "\n\nbl_parse_surface_all() {\n",
    """\n\nsx_parse_statement() {\n  local __start=$SX_POS\n  sx_parse_statement_inner || return\n  local __v=$RET\n  sx_mark_range \"$__v\" \"$__start\" \"$SX_POS\"\n  RET=$__v\n}\n\nbl_parse_surface_all() {\n""",
)
rep(
    "surface.sh",
    """  SX_SOURCE_NAME=$source_name; SX_SOURCE_LINE_BASE=$line_base\n  sx_lex \"$src\" || return\n""",
    """  SX_SOURCE_NAME=$source_name; SX_SOURCE_LINE_BASE=$line_base\n  bl_source_intern \"$source_name\"; SX_SOURCE_ID=$RET\n  sx_lex \"$src\" || return\n""",
)

# --- structural regression test ----------------------------------------------
Path("tests/provenance.sh").write_text(r'''#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source runtime.sh
source surface.sh

# Runtime initialization must be safe in strict-shell embedders and clear all
# value side tables before recycling heap IDs.
bl_runtime_init
bl_make_string_from_hex 00; old=$RET
[[ -v 'BL_STR_HEX[$old]' ]]
bl_runtime_init
bl_make_string plain; fresh=$RET
[[ $fresh == "$old" ]]
[[ ! -v 'BL_STR_HEX[$fresh]' ]]

src=$'let x = 1;\nprintln(x + 2);\n'
bl_parse_surface_all "$src" '/virtual/example.blx' 10
((${#BL_FORMS[@]} == 2))

f0=${BL_FORMS[0]}; f1=${BL_FORMS[1]}
sid=${BL_NODE_SOURCE[$f0]-}
[[ -n $sid && ${BL_SOURCE_NAME[$sid]-} == /virtual/example.blx ]]
[[ ${BL_NODE_START_LINE[$f0]-} == 10 && ${BL_NODE_START_COL[$f0]-} == 1 ]]
[[ ${BL_NODE_END_LINE[$f0]-} == 10 && ${BL_NODE_END_COL[$f0]-} == 11 ]]
[[ ${BL_NODE_SOURCE[$f1]-} == "$sid" ]]
[[ ${BL_NODE_START_LINE[$f1]-} == 11 && ${BL_NODE_START_COL[$f1]-} == 1 ]]
[[ ${BL_NODE_END_LINE[$f1]-} == 11 && ${BL_NODE_END_COL[$f1]-} == 16 ]]

# The argument is a nested call form for + and must retain its own narrower span.
bl_nth "$f1" 1; inner=$RET
[[ ${BL_NODE_SOURCE[$inner]-} == "$sid" ]]
[[ ${BL_NODE_START_LINE[$inner]-} == 11 && ${BL_NODE_START_COL[$inner]-} == 9 ]]
[[ ${BL_NODE_END_LINE[$inner]-} == 11 && ${BL_NODE_END_COL[$inner]-} == 14 ]]

# Re-parsing another chunk of the same file reuses the file/source identity.
before=$BL_SOURCE_SEQ
bl_parse_surface_all $'let y = 3;\n' '/virtual/example.blx' 30
[[ $BL_SOURCE_SEQ == "$before" ]]
f2=${BL_FORMS[0]}
[[ ${BL_NODE_SOURCE[$f2]-} == "$sid" && ${BL_NODE_START_LINE[$f2]-} == 30 ]]

# Metadata is side-table-only: ordinary value equality/hashing does not inspect it.
bl_make_string same; a=$RET
bl_make_string same; b=$RET
bl_node_span_set "$a" "$sid" 99 1 99 5
bl_equal_value "$a" "$b"
[[ $RET == true ]]
bl_hash_value "$a"; ha=$BL_HASH
bl_hash_value "$b"; hb=$BL_HASH
[[ $ha == "$hb" ]]

echo 'provenance: ok'
''')
Path("tests/provenance.sh").chmod(0o755)

rep(
    "tests/fast.sh",
    """bash tests/diagnostics.sh\n\nprintf '%s\\n' '[fast 2/4] focused interpreter/compiler suites (isolated, parallel)'\n""",
    """bash tests/diagnostics.sh\nbash tests/provenance.sh\n\nprintf '%s\\n' '[fast 2/4] focused interpreter/compiler suites (isolated, parallel)'\n""",
)
