from pathlib import Path


def rep(path, old, new, count=1):
    p=Path(path); s=p.read_text(); n=s.count(old)
    if n != count:
        raise SystemExit(f'{path}: expected {count} matches, got {n}: {old[:120]!r}')
    p.write_text(s.replace(old,new,count))

# runtime: dual raw/hex string representation + UTF-8 helpers.
rep('runtime.sh',
'''# Bytes are stored byte-by-byte because Bash variables cannot contain NUL.\ndeclare -Ag BL_BYTES_LEN=() BL_BYTE_AT=()\n''',
'''# Bytes are stored byte-by-byte because Bash variables cannot contain NUL.\ndeclare -Ag BL_BYTES_LEN=() BL_BYTE_AT=()\n# Strings are semantically valid Unicode text. Ordinary strings may keep a raw\n# Bash fast-path, but strings that Bash cannot represent losslessly (notably\n# embedded U+0000) use canonical lowercase UTF-8 hex in BL_STR_HEX. Runtime\n# code must use the helpers below rather than assuming BL_A is the string.\ndeclare -Ag BL_STR_HEX=()\n''')

rep('runtime.sh',
'''bl_make_int() { bl_alloc; BL_TYPE[$RET]=int; BL_A[$RET]=$1; }\nbl_make_string() { bl_alloc; BL_TYPE[$RET]=string; BL_A[$RET]=$1; [[ $BL_STRING_PROTO != nil ]] && BL_PROTO[$RET]=$BL_STRING_PROTO; }\n''',
'''bl_make_int() { bl_alloc; BL_TYPE[$RET]=int; BL_A[$RET]=$1; }\n\n# Convert a Bash-held UTF-8 byte string to canonical hex without depending on\n# locale character semantics. Bash cannot hold NUL, so this helper is only for\n# already-materializable host text.\nbl_text_to_utf8_hex() {\n  local s=$1 out= i c ord hx; local LC_ALL=C\n  for ((i=0;i<${#s};++i)); do\n    c=${s:i:1}; printf -v ord '%d' "'$c"; printf -v hx '%02x' "$ord"; out+=$hx\n  done\n  RET=$out\n}\n\nBL_UTF8_CP_COUNT=0\nbl_utf8_validate_hex() {\n  local hex=${1,,} n=${#1} i=0 count=0 b1 b2 b3 b4\n  (( n % 2 == 0 )) && [[ $hex =~ ^[0-9a-f]*$ ]] || return 1\n  while (( i < n )); do\n    b1=$((16#${hex:i:2}))\n    if (( b1 <= 0x7f )); then ((i+=2)) || true\n    elif (( b1 >= 0xc2 && b1 <= 0xdf )); then\n      (( i+4 <= n )) || return 1; b2=$((16#${hex:i+2:2})); (( b2>=0x80 && b2<=0xbf )) || return 1; ((i+=4)) || true\n    elif (( b1 >= 0xe0 && b1 <= 0xef )); then\n      (( i+6 <= n )) || return 1; b2=$((16#${hex:i+2:2})); b3=$((16#${hex:i+4:2}))\n      (( b3>=0x80 && b3<=0xbf )) || return 1\n      if (( b1 == 0xe0 )); then (( b2>=0xa0 && b2<=0xbf )) || return 1\n      elif (( b1 == 0xed )); then (( b2>=0x80 && b2<=0x9f )) || return 1\n      else (( b2>=0x80 && b2<=0xbf )) || return 1; fi\n      ((i+=6)) || true\n    elif (( b1 >= 0xf0 && b1 <= 0xf4 )); then\n      (( i+8 <= n )) || return 1; b2=$((16#${hex:i+2:2})); b3=$((16#${hex:i+4:2})); b4=$((16#${hex:i+6:2}))\n      (( b3>=0x80 && b3<=0xbf && b4>=0x80 && b4<=0xbf )) || return 1\n      if (( b1 == 0xf0 )); then (( b2>=0x90 && b2<=0xbf )) || return 1\n      elif (( b1 == 0xf4 )); then (( b2>=0x80 && b2<=0x8f )) || return 1\n      else (( b2>=0x80 && b2<=0xbf )) || return 1; fi\n      ((i+=8)) || true\n    else return 1; fi\n    ((count++)) || true\n  done\n  BL_UTF8_CP_COUNT=$count\n}\n\nBL_HEX_ZERO_AT=-1\nbl_hex_find_zero_byte() {\n  local hex=$1 i\n  BL_HEX_ZERO_AT=-1\n  for ((i=0;i<${#hex};i+=2)); do [[ ${hex:i:2} == 00 ]] && { BL_HEX_ZERO_AT=$i; return 0; }; done\n  return 1\n}\nbl_hex_has_zero_byte() { bl_hex_find_zero_byte "$1"; }\n\nbl_utf8_hex_to_text() {\n  local hex=${1,,} out= i pair ch\n  bl_hex_has_zero_byte "$hex" && return 1\n  for ((i=0;i<${#hex};i+=2)); do pair=${hex:i:2}; printf -v ch '%b' "\\x$pair"; out+=$ch; done\n  RET=$out\n}\n\nbl_make_string_from_hex() {\n  local hex=${1,,}\n  bl_utf8_validate_hex "$hex" || { bl_raise_error encoding 'invalid UTF-8'; return; }\n  bl_alloc; local out=$RET raw=\n  BL_TYPE[$out]=string\n  if bl_hex_has_zero_byte "$hex"; then BL_STR_HEX[$out]=$hex; BL_A[$out]=\n  else bl_utf8_hex_to_text "$hex" || return; raw=$RET; BL_A[$out]=$raw; fi\n  [[ $BL_STRING_PROTO != nil ]] && BL_PROTO[$out]=$BL_STRING_PROTO\n  RET=$out\n}\n\nbl_make_string() {\n  bl_text_to_utf8_hex "$1"; local hex=$RET\n  bl_make_string_from_hex "$hex"\n}\n\nbl_string_hex() {\n  local v=$1\n  [[ ${BL_TYPE[$v]-} == string ]] || { printf 'BLisp: expected string, got ' >&2; bl_repr "$v" >&2; printf '\\n' >&2; return 1; }\n  if [[ -v 'BL_STR_HEX[$v]' ]]; then RET=${BL_STR_HEX[$v]}; else bl_text_to_utf8_hex "${BL_A[$v]}"; fi\n}\n\n# Materialize a string for a host API that itself requires a C/Bash string.\n# U+0000 is supported by BLisp; only the host boundary rejects it where the\n# underlying OS/Bash interface cannot represent it.\nbl_string_value() {\n  local v=$1\n  bl_string_hex "$v" || return; local hex=$RET\n  if bl_hex_has_zero_byte "$hex"; then echo 'BLisp: this host API cannot accept a string containing U+0000' >&2; return 1; fi\n  if [[ ! -v 'BL_STR_HEX[$v]' ]]; then RET=${BL_A[$v]}; return; fi\n  bl_utf8_hex_to_text "$hex" || return\n}\n\nbl_string_write_fd() {\n  local v=$1 fd=$2 i pair esc= chunk=0\n  bl_string_hex "$v" || return; local hex=$RET\n  for ((i=0;i<${#hex};i+=2)); do\n    pair=${hex:i:2}; printf -v esc '%s\\x%s' "$esc" "$pair"; ((++chunk)) || true\n    if ((chunk>=2048)); then printf '%b' "$esc" >&"$fd" || return; esc=; chunk=0; fi\n  done\n  [[ -z $esc ]] || printf '%b' "$esc" >&"$fd"\n}\nbl_string_write_path() { local v=$1 path=$2 fd; : > "$path" || return; exec {fd}>"$path" || return; bl_string_write_fd "$v" "$fd"; local st=$?; exec {fd}>&-; return $st; }\n\nbl_utf8_hex_offset_for_cp() {\n  local hex=$1 target=$2 i=0 cp=0 n=${#1} b step\n  (( target >= 0 )) || return 1\n  while (( i < n && cp < target )); do\n    b=$((16#${hex:i:2}))\n    if ((b<=0x7f)); then step=2; elif ((b<=0xdf)); then step=4; elif ((b<=0xef)); then step=6; else step=8; fi\n    ((i+=step, cp++)) || true\n  done\n  (( cp == target )) || return 1\n  RET=$i\n}\nbl_string_cp_count() { bl_string_hex "$1" || return; bl_utf8_validate_hex "$RET" || return; bl_make_int "$BL_UTF8_CP_COUNT"; }\nbl_string_slice_value() {\n  local v=$1 start=$2 end=$3\n  bl_string_hex "$v" || return; local hex=$RET\n  bl_utf8_validate_hex "$hex" || return; local n=$BL_UTF8_CP_COUNT\n  ((start<0)) && start=$((n+start)); ((end<0)) && end=$((n+end)); ((start<0)) && start=0; ((end>n)) && end=$n; ((end<start)) && end=$start\n  bl_utf8_hex_offset_for_cp "$hex" "$start" || return; local a=$RET\n  bl_utf8_hex_offset_for_cp "$hex" "$end" || return; local b=$RET\n  bl_make_string_from_hex "${hex:a:b-a}"\n}\nbl_string_at_value() {\n  local v=$1 idx=$2\n  bl_string_hex "$v" || return; local hex=$RET\n  bl_utf8_validate_hex "$hex" || return; local n=$BL_UTF8_CP_COUNT\n  ((idx>=0 && idx<n)) || { bl_make_string ''; return; }\n  bl_utf8_hex_offset_for_cp "$hex" "$idx" || return; local a=$RET\n  bl_utf8_hex_offset_for_cp "$hex" "$((idx+1))" || return; local b=$RET\n  bl_make_string_from_hex "${hex:a:b-a}"\n}\nbl_string_index_of_values() {\n  local sv=$1 nv=$2\n  bl_string_hex "$sv" || return; local h=$RET\n  bl_string_hex "$nv" || return; local needle=$RET\n  [[ -n $needle ]] || { bl_make_int 0; return; }\n  local off=0 cp=0 n=${#h} b step\n  while ((off<=n-${#needle})); do\n    if [[ ${h:off:${#needle}} == "$needle" ]]; then bl_make_int "$cp"; return; fi\n    ((off<n)) || break\n    b=$((16#${h:off:2})); if ((b<=0x7f)); then step=2; elif ((b<=0xdf)); then step=4; elif ((b<=0xef)); then step=6; else step=8; fi\n    ((off+=step, cp++)) || true\n  done\n  bl_make_int -1\n}\n\n''')

# Remove old bl_string_value implementation now duplicated by helper block.
rep('runtime.sh',
'''bl_string_value() {\n  local v=$1\n  [[ ${BL_TYPE[$v]-} == string ]] || { printf 'BLisp: expected string, got ' >&2; bl_repr "$v" >&2; printf '\\n' >&2; return 1; }\n  RET=${BL_A[$v]}\n}\n\n''','')

# String repr/display become NUL-safe.
rep('runtime.sh',
'''# Printer.\nbl_escape_string() {\n  local s=$1\n  s=${s//\\\\/\\\\\\\\}; s=${s//\\\"/\\\\\\\"}; s=${s//$'\\n'/\\\\n}; s=${s//$'\\t'/\\\\t}; s=${s//$'\\r'/\\\\r}\n  RET=$s\n}\n''',
'''# Printer.\nbl_escape_string_value() {\n  local v=$1 i pair out= ch\n  bl_string_hex "$v" || return; local hex=$RET\n  for ((i=0;i<${#hex};i+=2)); do\n    pair=${hex:i:2}\n    case $pair in\n      00) out+='\\0' ;; 09) out+='\\t' ;; 0a) out+='\\n' ;; 0d) out+='\\r' ;;\n      22) out+='\\"' ;; 5c) out+='\\\\' ;;\n      *) printf -v ch '%b' "\\x$pair"; out+=$ch ;;\n    esac\n  done\n  RET=$out\n}\n''')
rep('runtime.sh','''    string) bl_escape_string "${BL_A[$v]}"; printf '\"%s\"' "$RET" ;;''','''    string) bl_escape_string_value "$v"; printf '\"%s\"' "$RET" ;;''')
rep('runtime.sh',
'''bl_display() {\n  local v=$1\n  if [[ ${BL_TYPE[$v]-} == string ]]; then printf '%s' "${BL_A[$v]}"; else bl_repr "$v"; fi\n}\n''',
'''bl_display() {\n  local v=$1\n  if [[ ${BL_TYPE[$v]-} == string ]]; then bl_string_write_fd "$v" 1; else bl_repr "$v"; fi\n}\n''')

# Classic Lisp lexer stores string token payload as UTF-8 hex, enabling \\0.
rep('runtime.sh','''bl_lex() {\n  local src=$1 i=0 n=${#1} c tok buf esc\n''','''bl_lex() {\n  local src=$1 i=0 n=${#1} c tok buf esc hx\n''')
rep('runtime.sh','            case $esc in n) buf+=$\'\\n\';; t) buf+=$\'\\t\';; r) buf+=$\'\\r\';; \'"\') buf+=\'"\';; \'\\\') buf+=\'\\\';; *) buf+="$esc";; esac\n          else buf+="$c"; fi\n','            case $esc in\n              n) buf+=0a;; t) buf+=09;; r) buf+=0d;; 0) buf+=00;; \'"\') buf+=22;; \'\\\') buf+=5c;;\n              *) bl_text_to_utf8_hex "$esc"; buf+=$RET;;\n            esac\n          else bl_text_to_utf8_hex "$c"; buf+=$RET; fi\n')
rep('runtime.sh','        BL_TOKENS+=("S:$buf")\n','        BL_TOKENS+=("H:$buf")\n')
rep('runtime.sh','''    S:*) bl_make_string "${tok:2}" ;;''','''    H:*) bl_make_string_from_hex "${tok:2}" ;;\n    S:*) bl_make_string "${tok:2}" ;;''')

# Core property/string iteration/len use representation helpers.
rep('runtime.sh','''    string|symbol|int) RET=${BL_A[$v]} ;;''',
'''    string)\n      bl_string_hex "$v" || return; local __kh=$RET\n      if [[ -v 'BL_STR_HEX[$v]' ]]; then RET=$'\\x1e'"$__kh"\n      else bl_utf8_hex_to_text "$__kh" || return; local __kr=$RET; if [[ $__kr == $'\\x1e'* || $__kr == *'|'* ]]; then RET=$'\\x1e'"$__kh"; else RET=$__kr; fi; fi ;;\n    symbol|int) RET=${BL_A[$v]} ;;''')
rep('runtime.sh','''  if [[ ${BL_TYPE[$obj]-} == string && $key == length ]]; then bl_make_int "${#BL_A[$obj]}"; return; fi\n  if [[ ${BL_TYPE[$obj]-} == string && $key =~ ^[0-9]+$ ]]; then\n    local i=$key s=${BL_A[$obj]}; (( i >= 0 && i < ${#s} )) && bl_make_string "${s:i:1}" || RET=nil; return\n  fi\n''',
'''  if [[ ${BL_TYPE[$obj]-} == string && $key == length ]]; then bl_string_cp_count "$obj"; return; fi\n  if [[ ${BL_TYPE[$obj]-} == string && $key =~ ^[0-9]+$ ]]; then\n    bl_string_hex "$obj" || return; local __sh=$RET; bl_utf8_validate_hex "$__sh" || return; local __sn=$BL_UTF8_CP_COUNT\n    if (( key >= 0 && key < __sn )); then bl_string_at_value "$obj" "$key"; else RET=nil; fi; return\n  fi\n''')
rep('runtime.sh','''      string) idx=${BL_B[$it]}; local raw=${BL_A[$src]}; if ((idx>=${#raw})); then BL_ITER_DONE=1; RET=nil; else bl_make_string "${raw:idx:1}"; BL_B[$it]=$((idx+1)); fi ;;''',
'''      string) idx=${BL_B[$it]}; bl_string_hex "$src" || return; local __sh=$RET; bl_utf8_validate_hex "$__sh" || return; if ((idx>=BL_UTF8_CP_COUNT)); then BL_ITER_DONE=1; RET=nil; else bl_string_at_value "$src" "$idx"; BL_B[$it]=$((idx+1)); fi ;;''')

# value->string now returns an actual string value, so NUL survives composition.
start='''bl_value_to_string() {\n  local v=$1 fn out\n  case $v in nil|true|false) RET=$v; return;; esac\n  case ${BL_TYPE[$v]-} in\n    string|int|float) RET=${BL_A[$v]} ;;\n    symbol) RET=${BL_C[$v]-${BL_A[$v]}} ;;\n    object|array|bytes|builtin|closure|compiled|bound)\n      bl_prop_get_key "$v" __str__; fn=$RET\n      if [[ $fn != nil ]]; then\n        bl_apply_this "$fn" "$v" || return\n        [[ ${BL_TYPE[$RET]-} == string ]] || { echo 'BLisp: __str__ must return string' >&2; return 1; }\n        RET=${BL_A[$RET]}\n      else\n        local tmp; tmp=$(bl_repr "$v"); RET=$tmp\n      fi\n      ;;\n    *) local tmp; tmp=$(bl_repr "$v"); RET=$tmp ;;\n  esac\n}\n'''
replacement='''bl_value_to_string() {\n  local v=$1 fn tmp\n  case ${BL_TYPE[$v]-} in\n    string) RET=$v; return ;;\n    int|float) bl_make_string "${BL_A[$v]}"; return ;;\n    symbol) bl_make_string "${BL_C[$v]-${BL_A[$v]}}"; return ;;\n    object|array|bytes|builtin|closure|compiled|bound)\n      bl_prop_get_key "$v" __str__; fn=$RET\n      if [[ $fn != nil ]]; then\n        bl_apply_this "$fn" "$v" || return\n        [[ ${BL_TYPE[$RET]-} == string ]] || { echo 'BLisp: __str__ must return string' >&2; return 1; }\n        return\n      fi ;;\n  esac\n  case $v in nil|true|false) bl_make_string "$v"; return;; esac\n  tmp=$(bl_repr "$v"); bl_make_string "$tmp"\n}\n'''
rep('runtime.sh',start,replacement)

rep('runtime.sh','''    string) bl_make_int "${#BL_A[$v]}" ;;''','''    string) bl_string_cp_count "$v" ;;''')

# keys/entries decode sentinel-encoded NUL/unsafe property keys.
rep('runtime.sh','''  for ((i=0;i<n;++i)); do k=${BL_KEY_AT["$obj|$i"]}; [[ -v 'BL_PROP["$obj|$k"]' ]] || continue; bl_make_string "$k"; vals+=("$RET"); done\n''',
'''  for ((i=0;i<n;++i)); do k=${BL_KEY_AT["$obj|$i"]}; [[ -v 'BL_PROP["$obj|$k"]' ]] || continue; if [[ $k == $'\\x1e'* ]]; then bl_make_string_from_hex "${k:1}"; else bl_make_string "$k"; fi; vals+=("$RET"); done\n''')
rep('runtime.sh','''    bl_make_string "$k"; local kv=$RET; bl_make_array "$kv" "${BL_PROP["$obj|$k"]}"; out+=("$RET")\n''',
'''    if [[ $k == $'\\x1e'* ]]; then bl_make_string_from_hex "${k:1}"; else bl_make_string "$k"; fi; local kv=$RET; bl_make_array "$kv" "${BL_PROP["$obj|$k"]}"; out+=("$RET")\n''')

# bytes <-> string encode/decode is direct canonical UTF-8 storage.
rep('runtime.sh','''      string)\n        s=${BL_A[$v]}; local -a out=(); local LC_ALL=C\n        for ((i=0;i<${#s};++i)); do printf -v ord '%d' "'${s:i:1}"; out+=("$ord"); done\n        bl_make_bytes "${out[@]}"; return ;;\n''',
'''      string)\n        bl_string_hex "$v" || return; local hex=$RET pair; local -a out=()\n        for ((i=0;i<${#hex};i+=2)); do pair=${hex:i:2}; out+=("$((16#$pair))"); done\n        bl_make_bytes "${out[@]}"; return ;;\n''')
rep('runtime.sh','''  local i n=${BL_BYTES_LEN[$b]-0} x esc= raw\n  for ((i=0;i<n;++i)); do\n    x=${BL_BYTE_AT["$b|$i"]}\n    ((x!=0)) || { bl_raise_error encoding 'cannot decode NUL-containing bytes into a Bash-backed string'; return; }\n    printf -v esc '%s\\\\%03o' "$esc" "$x"\n  done\n  printf -v raw '%b' "$esc"; bl_make_string "$raw"\n''',
'''  local i n=${BL_BYTES_LEN[$b]-0} x hx hex=\n  for ((i=0;i<n;++i)); do x=${BL_BYTE_AT["$b|$i"]}; printf -v hx '%02x' "$x"; hex+=$hx; done\n  bl_make_string_from_hex "$hex"\n''')
rep('runtime.sh','''  bl_builtin_bytes "$s"\n}''','''  bl_builtin_bytes "$s"\n}''',1)  # unchanged anchor, ensures presence

# Hash strings by canonical UTF-8 bytes.
rep('runtime.sh','''    string) bl_hash_text "s:${BL_A[$v]}" ;;''','''    string) bl_string_hex "$v" || return; bl_hash_text "s:$RET" ;;''')

# TCP/file/process string writes must stream bytes, not materialize via Bash.
rep('runtime.sh','''    string) printf '%s' "${BL_A[$data]}" >&"$fd" || return; n=${#BL_A[$data]} ;;''',
'''    string) bl_string_hex "$data" || return; local __sh=$RET; bl_string_write_fd "$data" "$fd" || return; n=$((${#__sh}/2)) ;;''')

# process stdin has two identical sites.
rep('runtime.sh', '''elif [[ ${BL_TYPE[$stdin]-} == string ]]; then printf '%s' "${BL_A[$stdin]}" > "$in" || { rm -rf "$tmp"; return; };''',
'''elif [[ ${BL_TYPE[$stdin]-} == string ]]; then bl_string_write_path "$stdin" "$in" || { rm -rf "$tmp"; return; };''', count=2)
# GC knows about backing table.
rep('runtime.sh','''local -a excluded=(BL_TYPE BL_A BL_B BL_C BL_PROP BL_PROTO BL_KEY_COUNT BL_KEY_AT BL_ARR_LEN BL_BYTES_LEN BL_BYTE_AT BL_ENV_PARENT''',
'''local -a excluded=(BL_TYPE BL_A BL_B BL_C BL_PROP BL_PROTO BL_KEY_COUNT BL_KEY_AT BL_ARR_LEN BL_BYTES_LEN BL_BYTE_AT BL_STR_HEX BL_ENV_PARENT''')
rep('runtime.sh', '''unset 'BL_TYPE[$v]' 'BL_A[$v]' 'BL_B[$v]' 'BL_C[$v]' 'BL_PROTO[$v]' 'BL_KEY_COUNT[$v]' 'BL_ARR_LEN[$v]' 'BL_BYTES_LEN[$v]'\n''',
'''unset 'BL_TYPE[$v]' 'BL_A[$v]' 'BL_B[$v]' 'BL_C[$v]' 'BL_PROTO[$v]' 'BL_KEY_COUNT[$v]' 'BL_ARR_LEN[$v]' 'BL_BYTES_LEN[$v]' 'BL_STR_HEX[$v]'\n''')

# Array join and all string prototype/core builtins operate on encoded strings.
rep('runtime.sh',
'''bl_builtin_arr_join() { local a=$1; shift; [[ ${BL_TYPE[$a]-} == array ]] || return 1; local sep=,; if (($#)); then bl_string_value "$1" || return; sep=$RET; fi; local out= i n; n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do ((i)) && out+=$sep; bl_prop_get_key "$a" "$i"; bl_value_to_string "$RET" || return; out+=$RET; done; bl_make_string "$out"; }\n''',
'''bl_builtin_arr_join() { local a=$1; shift; [[ ${BL_TYPE[$a]-} == array ]] || return 1; local sepv; if (($#)); then sepv=$1; [[ ${BL_TYPE[$sepv]-} == string ]] || { echo 'BLisp: join separator must be string' >&2; return 1; }; else bl_make_string ','; sepv=$RET; fi; bl_string_hex "$sepv" || return; local seph=$RET out= i n; n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do ((i)) && out+=$seph; bl_prop_get_key "$a" "$i"; bl_value_to_string "$RET" || return; bl_string_hex "$RET" || return; out+=$RET; done; bl_make_string_from_hex "$out"; }\n''')

# Replace String.prototype block up to Boolean conversion.
old_block='''# String.prototype-like methods.\nbl_builtin_str_includes() { local s=$1; shift; bl_expect_arity $# 1 includes || return; bl_string_value "$s" || return; local raw=$RET; bl_string_value "$1" || return; [[ $raw == *"$RET"* ]] && RET=true || RET=false; }\nbl_builtin_str_starts_with() { local s=$1; shift; bl_expect_arity $# 1 startsWith || return; bl_string_value "$s" || return; local raw=$RET; bl_string_value "$1" || return; [[ $raw == "$RET"* ]] && RET=true || RET=false; }\nbl_builtin_str_ends_with() { local s=$1; shift; bl_expect_arity $# 1 endsWith || return; bl_string_value "$s" || return; local raw=$RET; bl_string_value "$1" || return; [[ $raw == *"$RET" ]] && RET=true || RET=false; }\nbl_builtin_str_slice() { local s=$1; shift; bl_expect_min_arity $# 1 slice || return; bl_string_value "$s" || return; local raw=$RET n=${#RET}; bl_int_value "$1" || return; local start=$RET end=$n; if (($#>=2)); then bl_int_value "$2" || return; end=$RET; fi; ((start<0)) && start=$((n+start)); ((end<0)) && end=$((n+end)); ((start<0)) && start=0; ((end>n)) && end=$n; ((end<start)) && end=$start; bl_make_string "${raw:start:end-start}"; }\nbl_builtin_str_split() { local s=$1; shift; bl_expect_arity $# 1 split || return; bl_string_value "$s" || return; local raw=$RET; bl_string_value "$1" || return; local d=$RET; [[ -n $d ]] || { echo 'BLisp: split delimiter may not be empty' >&2; return 1; }; local -a out=(); local part; while [[ $raw == *"$d"* ]]; do part=${raw%%"$d"*}; bl_make_string "$part"; out+=("$RET"); raw=${raw#*"$d"}; done; bl_make_string "$raw"; out+=("$RET"); bl_make_array "${out[@]}"; }\nbl_builtin_str_upper() { local s=$1; shift; bl_expect_arity $# 0 toUpperCase || return; bl_string_value "$s" || return; bl_make_string "${RET^^}"; }\nbl_builtin_str_lower() { local s=$1; shift; bl_expect_arity $# 0 toLowerCase || return; bl_string_value "$s" || return; bl_make_string "${RET,,}"; }\nbl_builtin_str_repeat() { local s=$1; shift; bl_expect_arity $# 1 repeat || return; bl_string_value "$s" || return; local raw=$RET; bl_int_value "$1" || return; local n=$RET out= i; ((n>=0)) || { echo 'BLisp: repeat count must be nonnegative' >&2; return 1; }; for ((i=0;i<n;++i)); do out+=$raw; done; bl_make_string "$out"; }\nbl_builtin_str_char_at() { local s=$1; shift; bl_expect_arity $# 1 charAt || return; bl_string_value "$s" || return; local raw=$RET; bl_int_value "$1" || return; local i=$RET; if ((i<0 || i>=${#raw})); then bl_make_string ''; else bl_make_string "${raw:i:1}"; fi; }\nbl_builtin_str_index_of() {\n  local s=$1; shift; bl_expect_arity $# 1 string.indexOf || return\n  bl_string_value "$s" || return; local raw=$RET\n  bl_string_value "$1" || return; local needle=$RET\n  if [[ $needle == '' ]]; then bl_make_int 0; return; fi\n  local i max=$((${#raw}-${#needle}))\n  for ((i=0;i<=max;++i)); do\n    if [[ ${raw:i:${#needle}} == "$needle" ]]; then bl_make_int "$i"; return; fi\n  done\n  bl_make_int -1\n}\nbl_builtin_str_trim() { local s=$1; shift; bl_expect_arity $# 0 trim || return; bl_string_value "$s" || return; local raw=$RET; raw="${raw#"${raw%%[![:space:]]*}"}"; raw="${raw%"${raw##*[![:space:]]}"}"; bl_make_string "$raw"; }\nbl_builtin_str_lines() { local s=$1; shift; bl_expect_arity $# 0 lines || return; bl_string_value "$s" || return; local raw=$RET; bl_make_string $'\\n'; local nl=$RET; bl_builtin_string_split "$s" "$nl" || return; bl_list_to_array "$RET" || return; bl_make_array "${BL_LIST_RESULT[@]}"; }\nbl_builtin_str_words() { local s=$1; shift; bl_expect_arity $# 0 words || return; bl_string_value "$s" || return; local raw=${RET//$'\\n'/ }; local -a ws=(); read -r -a ws <<< "$raw"; local -a out=(); local w; for w in "${ws[@]}"; do bl_make_string "$w"; out+=("$RET"); done; bl_make_array "${out[@]}"; }\nbl_builtin_to_string() { bl_expect_arity $# 1 String || return; bl_value_to_string "$1" || return; local raw=$RET; bl_make_string "$raw"; }\n'''
new_block='''# String.prototype-like methods. Core operations work on canonical UTF-8 so\n# embedded U+0000 is no different from any other code point.\nbl_builtin_str_includes() { local s=$1; shift; bl_expect_arity $# 1 includes || return; bl_string_index_of_values "$s" "$1" || return; (( ${BL_A[$RET]} >= 0 )) && RET=true || RET=false; }\nbl_builtin_str_starts_with() { local s=$1; shift; bl_expect_arity $# 1 startsWith || return; bl_string_hex "$s" || return; local h=$RET; bl_string_hex "$1" || return; [[ $h == "$RET"* ]] && RET=true || RET=false; }\nbl_builtin_str_ends_with() { local s=$1; shift; bl_expect_arity $# 1 endsWith || return; bl_string_hex "$s" || return; local h=$RET; bl_string_hex "$1" || return; [[ $h == *"$RET" ]] && RET=true || RET=false; }\nbl_builtin_str_slice() { local s=$1; shift; bl_expect_min_arity $# 1 slice || return; bl_string_cp_count "$s" || return; local n=${BL_A[$RET]}; bl_int_value "$1" || return; local start=$RET end=$n; if (($#>=2)); then bl_int_value "$2" || return; end=$RET; fi; bl_string_slice_value "$s" "$start" "$end"; }\nbl_builtin_str_split() { local s=$1; shift; bl_expect_arity $# 1 split || return; bl_string_hex "$s" || return; local h=$RET; bl_string_hex "$1" || return; local d=$RET; [[ -n $d ]] || { echo 'BLisp: split delimiter may not be empty' >&2; return 1; }; local -a out=(); local off b step found part; while :; do off=0; found=-1; while ((off<=${#h}-${#d})); do if [[ ${h:off:${#d}} == "$d" ]]; then found=$off; break; fi; ((off<${#h})) || break; b=$((16#${h:off:2})); if ((b<=0x7f)); then step=2; elif ((b<=0xdf)); then step=4; elif ((b<=0xef)); then step=6; else step=8; fi; ((off+=step)) || true; done; ((found>=0)) || break; part=${h:0:found}; bl_make_string_from_hex "$part"; out+=("$RET"); h=${h:found+${#d}}; done; bl_make_string_from_hex "$h"; out+=("$RET"); bl_make_array "${out[@]}"; }\nbl_string_case_map() { local s=$1 mode=$2 rest part raw mapped out= idx; bl_string_hex "$s" || return; rest=$RET; while bl_hex_find_zero_byte "$rest"; do idx=$BL_HEX_ZERO_AT; part=${rest:0:idx}; rest=${rest:idx+2}; bl_utf8_hex_to_text "$part" || return; raw=$RET; if [[ $mode == upper ]]; then mapped=${raw^^}; else mapped=${raw,,}; fi; bl_text_to_utf8_hex "$mapped"; out+="$RET"00; done; bl_utf8_hex_to_text "$rest" || return; raw=$RET; if [[ $mode == upper ]]; then mapped=${raw^^}; else mapped=${raw,,}; fi; bl_text_to_utf8_hex "$mapped"; out+=$RET; bl_make_string_from_hex "$out"; }\nbl_builtin_str_upper() { local s=$1; shift; bl_expect_arity $# 0 toUpperCase || return; bl_string_case_map "$s" upper; }\nbl_builtin_str_lower() { local s=$1; shift; bl_expect_arity $# 0 toLowerCase || return; bl_string_case_map "$s" lower; }\nbl_builtin_str_repeat() { local s=$1; shift; bl_expect_arity $# 1 repeat || return; bl_string_hex "$s" || return; local h=$RET; bl_int_value "$1" || return; local n=$RET out= i; ((n>=0)) || { echo 'BLisp: repeat count must be nonnegative' >&2; return 1; }; for ((i=0;i<n;++i)); do out+=$h; done; bl_make_string_from_hex "$out"; }\nbl_builtin_str_char_at() { local s=$1; shift; bl_expect_arity $# 1 charAt || return; bl_int_value "$1" || return; bl_string_at_value "$s" "$RET"; }\nbl_builtin_str_index_of() { local s=$1; shift; bl_expect_arity $# 1 string.indexOf || return; bl_string_index_of_values "$s" "$1"; }\nbl_builtin_str_trim() { local s=$1; shift; bl_expect_arity $# 0 trim || return; bl_string_hex "$s" || return; local h=$RET start=0 end=${#RET} pair; while ((start<end)); do pair=${h:start:2}; case $pair in 09|0a|0b|0c|0d|20) ((start+=2)) || true;; *) break;; esac; done; while ((end>start)); do pair=${h:end-2:2}; case $pair in 09|0a|0b|0c|0d|20) ((end-=2)) || true;; *) break;; esac; done; bl_make_string_from_hex "${h:start:end-start}"; }\nbl_builtin_str_lines() { local s=$1; shift; bl_expect_arity $# 0 lines || return; bl_make_string_from_hex 0a; local nl=$RET; bl_builtin_str_split "$s" "$nl"; }\nbl_builtin_str_words() { local s=$1; shift; bl_expect_arity $# 0 words || return; bl_string_hex "$s" || return; local h=$RET token= pair i; local -a out=(); for ((i=0;i<${#h};i+=2)); do pair=${h:i:2}; case $pair in 09|0a|0b|0c|0d|20) if [[ -n $token ]]; then bl_make_string_from_hex "$token"; out+=("$RET"); token=; fi ;; *) token+=$pair ;; esac; done; if [[ -n $token ]]; then bl_make_string_from_hex "$token"; out+=("$RET"); fi; bl_make_array "${out[@]}"; }\nbl_builtin_to_string() { bl_expect_arity $# 1 String || return; bl_value_to_string "$1"; }\n'''
rep('runtime.sh',old_block,new_block)

# Core Lisp string helpers.
rep('runtime.sh','''bl_builtin_string_append() { local out= v; for v in "$@"; do bl_string_value "$v" || return; out+=$RET; done; bl_make_string "$out"; }''',
'''bl_builtin_string_append() { local out= v; for v in "$@"; do bl_string_hex "$v" || return; out+=$RET; done; bl_make_string_from_hex "$out"; }''')
rep('runtime.sh','''bl_builtin_string_length() { bl_expect_arity $# 1 string-length || return; bl_string_value "$1" || return; bl_make_int "${#RET}"; }''',
'''bl_builtin_string_length() { bl_expect_arity $# 1 string-length || return; bl_string_cp_count "$1"; }''')
rep('runtime.sh','''bl_builtin_string_eq() { bl_expect_arity $# 2 string=? || return; bl_string_value "$1" || return; local a=$RET; bl_string_value "$2" || return; [[ $a == "$RET" ]] && RET=true || RET=false; }''',
'''bl_builtin_string_eq() { bl_expect_arity $# 2 string=? || return; bl_string_hex "$1" || return; local a=$RET; bl_string_hex "$2" || return; [[ $a == "$RET" ]] && RET=true || RET=false; }''')
rep('runtime.sh','''  bl_string_value "$1" || return; local s=$RET\n  bl_int_value "$2" || return; local start=$RET\n  bl_int_value "$3" || return; local end=$RET\n  (( start >= 0 && end >= start && end <= ${#s} )) || { echo 'BLisp: substring bounds' >&2; return 1; }\n  bl_make_string "${s:start:end-start}"\n''',
'''  bl_int_value "$2" || return; local start=$RET\n  bl_int_value "$3" || return; local end=$RET\n  bl_string_cp_count "$1" || return; local n=${BL_A[$RET]}\n  (( start >= 0 && end >= start && end <= n )) || { echo 'BLisp: substring bounds' >&2; return 1; }\n  bl_string_slice_value "$1" "$start" "$end"\n''')
# Replace classic split/join/contains with prototype-safe helpers.
rep('runtime.sh','''  bl_string_value "$1" || return; local s=$RET\n  bl_string_value "$2" || return; local d=$RET\n  [[ -n $d ]] || { echo 'BLisp: string-split delimiter may not be empty' >&2; return 1; }\n  local -a vals=(); local part\n  while [[ $s == *"$d"* ]]; do\n    part=${s%%"$d"*}; bl_make_string "$part"; vals+=("$RET"); s=${s#*"$d"}\n  done\n  bl_make_string "$s"; vals+=("$RET")\n  bl_list_from_array "${vals[@]}"\n''',
'''  bl_string_hex "$1" || return; local s=$RET\n  bl_string_hex "$2" || return; local d=$RET\n  [[ -n $d ]] || { echo 'BLisp: string-split delimiter may not be empty' >&2; return 1; }\n  local -a vals=(); local part\n  while [[ $s == *"$d"* ]]; do\n    part=${s%%"$d"*}; bl_make_string_from_hex "$part"; vals+=("$RET"); s=${s#*"$d"}\n  done\n  bl_make_string_from_hex "$s"; vals+=("$RET")\n  bl_list_from_array "${vals[@]}"\n''')
rep('runtime.sh','''  bl_string_value "$2" || return; local d=$RET out= first=1 cur=$list\n  while [[ $cur != nil ]]; do\n    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: string-join expects proper list' >&2; return 1; }\n    bl_string_value "${BL_A[$cur]}" || return\n    if (( first )); then out=$RET; first=0; else out+="$d$RET"; fi\n    cur=${BL_B[$cur]}\n  done\n  bl_make_string "$out"\n''',
'''  bl_string_hex "$2" || return; local d=$RET out= first=1 cur=$list\n  while [[ $cur != nil ]]; do\n    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: string-join expects proper list' >&2; return 1; }\n    bl_string_hex "${BL_A[$cur]}" || return\n    if (( first )); then out=$RET; first=0; else out+="$d$RET"; fi\n    cur=${BL_B[$cur]}\n  done\n  bl_make_string_from_hex "$out"\n''')
rep('runtime.sh','''  bl_string_value "$1" || return; local s=$RET\n  bl_string_value "$2" || return; local needle=$RET\n  [[ $s == *"$needle"* ]] && RET=true || RET=false\n''',
'''  bl_string_hex "$1" || return; local s=$RET\n  bl_string_hex "$2" || return; local needle=$RET\n  [[ $s == *"$needle"* ]] && RET=true || RET=false\n''')

# File text I/O is binary-safe + UTF-8 validated.
rep('runtime.sh',
'''  bl_string_value "$1" || return; local path=$RET data\n  # Sentinel preserves trailing newlines that command substitution would otherwise strip.\n  data=$( { cat -- "$path" 2>/dev/null || exit $?; printf '\\034'; } ) || { bl_raise_error io "cannot read text: $path"; return; }\n  data=${data%$'\\034'}\n  bl_make_string "$data"\n}\nbl_builtin_write_file() { bl_expect_arity $# 2 write-file || return; bl_string_value "$1" || return; local path=$RET; bl_string_value "$2" || return; local data=$RET; printf '%s' "$data" > "$path" 2>/dev/null || { bl_raise_error io "cannot write text: $path"; return; }; RET=nil; }\n''',
'''  bl_string_value "$1" || return; local path=$RET\n  bl_bytes_read_path "$path" || { bl_raise_error io "cannot read text: $path"; return; }; local b=$RET\n  bl_builtin_bytes_to_string "$b"\n}\nbl_builtin_write_file() { bl_expect_arity $# 2 write-file || return; bl_string_value "$1" || return; local path=$RET; [[ ${BL_TYPE[$2]-} == string ]] || { echo 'BLisp: write-file expects string data' >&2; return 1; }; bl_string_write_path "$2" "$path" || { bl_raise_error io "cannot write text: $path"; return; }; RET=nil; }\n''')

# Equality/ordering use canonical bytes for strings.
rep('runtime.sh','''  if [[ $t1 == "$t2" && ( $t1 == int || $t1 == float || $t1 == string || $t1 == symbol ) && ${BL_A[$1]} == "${BL_A[$2]}" ]]; then RET=true; else RET=false; fi\n''',
'''  if [[ $t1 == string && $t2 == string ]]; then bl_string_hex "$1" || return; local __a=$RET; bl_string_hex "$2" || return; [[ $__a == "$RET" ]] && RET=true || RET=false; return; fi\n  if [[ $t1 == "$t2" && ( $t1 == int || $t1 == float || $t1 == symbol ) && ${BL_A[$1]} == "${BL_A[$2]}" ]]; then RET=true; else RET=false; fi\n''')
rep('runtime.sh','''    int|float|string|symbol) [[ ${BL_A[$x]} == "${BL_A[$y]}" ]] && RET=true || RET=false ;;''',
'''    string) bl_string_hex "$x" || return; local __sx=$RET; bl_string_hex "$y" || return; [[ $__sx == "$RET" ]] && RET=true || RET=false ;;\n    int|float|symbol) [[ ${BL_A[$x]} == "${BL_A[$y]}" ]] && RET=true || RET=false ;;''')
rep('runtime.sh','''    local av=${BL_A[$a]} bv=${BL_A[$b]}; local LC_ALL=C ok=0\n''',
'''    bl_string_hex "$a" || return; local av=$RET; bl_string_hex "$b" || return; local bv=$RET; local LC_ALL=C ok=0\n''')

# compiler serializes string constants by canonical hex, so compiled NUL is safe.
rep('compiler.sh','''    string) comp_q "${BL_A[$v]}"; comp_emit "bl_make_string $COMP_REPLY" ;;''',
'''    string) bl_string_hex "$v" || return; comp_q "$RET"; comp_emit "bl_make_string_from_hex $COMP_REPLY" ;;''')
rep('compiler.sh','''    string) comp_q "${BL_A[$expr]}"; comp_emit "bl_make_string $COMP_REPLY"; return ;;''',
'''    string) bl_string_hex "$expr" || return; comp_q "$RET"; comp_emit "bl_make_string_from_hex $COMP_REPLY"; return ;;''')

# Surface string lexer stores hex rather than raw Bash strings.
old='''    if [[ $c == '\"' || $c == "'" ]]; then\n      q=$c; ((i++)) || true; buf=\n      while ((i<n)); do\n        c=${src:i:1}; ((i++)) || true\n        [[ $c == "$q" ]] && break\n        if [[ $c == '\\\\' ]]; then\n          ((i<n)) || { sx_lex_error 'unterminated string escape'; return 1; }\n          esc=${src:i:1}; ((i++)) || true\n          case $esc in\n            n) buf+=$'\\n';; t) buf+=$'\\t';; r) buf+=$'\\r';;\n            0) sx_lex_error 'this reference implementation cannot store NUL in strings; use bytes'; return 1;;\n            '\\\\') buf+='\\\\';; '\"') buf+='\"';; "'") buf+="'";;\n            *) buf+="$esc";;\n          esac\n        else\n          buf+="$c"\n        fi\n      done\n      [[ $c == "$q" ]] || { sx_lex_error 'unterminated string'; return 1; }\n      sx_tok str "$buf" "$gap"; gap=0; continue\n    fi\n'''
new='''    if [[ $c == '\"' || $c == "'" ]]; then\n      q=$c; ((i++)) || true; buf=\n      while ((i<n)); do\n        c=${src:i:1}; ((i++)) || true\n        [[ $c == "$q" ]] && break\n        if [[ $c == '\\\\' ]]; then\n          ((i<n)) || { sx_lex_error 'unterminated string escape'; return 1; }\n          esc=${src:i:1}; ((i++)) || true\n          case $esc in\n            n) buf+=0a;; t) buf+=09;; r) buf+=0d;; 0) buf+=00;;\n            '\\\\') buf+=5c;; '\"') buf+=22;; "'") buf+=27;;\n            *) bl_text_to_utf8_hex "$esc"; buf+=$RET;;\n          esac\n        else bl_text_to_utf8_hex "$c"; buf+=$RET\n        fi\n      done\n      [[ $c == "$q" ]] || { sx_lex_error 'unterminated string'; return 1; }\n      sx_tok str "$buf" "$gap"; gap=0; continue\n    fi\n'''
rep('surface.sh',old,new)
# All parser str tokens are now hex. There are two direct datum/primary cases.
rep('surface.sh','''    str) ((SX_POS++)) || true; bl_make_string "$v" ;;''','''    str) ((SX_POS++)) || true; bl_make_string_from_hex "$v" ;;''',count=2)
# Object literal string keys: key token is hex, not human text.
old='''      elif sx_type_is id || sx_type_is str || sx_type_is num; then\n        key=${SX_TOK_VAL[SX_POS]}; [[ ${SX_TOK_TYPE[SX_POS]} == id ]] && key_is_id=1\n        ((SX_POS++)) || true; sx_str "$key"; key_ast=$RET\n'''
new='''      elif sx_type_is id || sx_type_is str || sx_type_is num; then\n        key=${SX_TOK_VAL[SX_POS]}; local __kt=${SX_TOK_TYPE[SX_POS]}; [[ $__kt == id ]] && key_is_id=1\n        ((SX_POS++)) || true; if [[ $__kt == str ]]; then bl_make_string_from_hex "$key"; else sx_str "$key"; fi; key_ast=$RET\n'''
rep('surface.sh',old,new)

# Add regression suite.
Path('tests/string-nul.blx').write_text(r'''fn hexOf(s) { return s.encode("utf-8").hex(); }

let nul = "\0";
assert(nul.length == 1, "NUL counts as one code point");
assert(hexOf(nul) == "00");

let s = "A\0é💩B";
assert(s.length == 5);
assert(s[0] == "A");
assert(s[1] == nul);
assert(s[2] == "é");
assert(s[3] == "💩");
assert(hexOf(s.slice(1, 4)) == "00c3a9f09f92a9");

let decoded = bytes([65, 0, 66]).decode("utf-8");
assert(decoded == "A\0B");
assert(hexOf(decoded + "!") == "41004221");
assert(hash(decoded) == hash("A\0B"));
assert(decoded.includes(nul));
assert(decoded.indexOf(nul) == 1);
assert(decoded.split(nul).join("|") == "A|B");
assert(["x", nul, "y"].join("-").encode().hex() == "782d002d79");
assert("a\0b".upper().encode().hex() == "410042");
assert(" A\0B ".trim().encode().hex() == "410042");

let obj = {};
obj[nul] = 42;
assert(obj[nul] == 42);
assert(Object.keys(obj)[0] == nul);

let bad = attempt(() => bytes([0xc0, 0x80]).decode("utf-8"));
assert(!bad.ok);

let path = "/tmp/blisp-nul-string-roundtrip.txt";
writeFile(path, s);
assert(readFile(path) == s);
assert(readBytes(path).hex() == hexOf(s));

let p = process.run(["bash", "-c", "cat"], {stdin: decoded});
assert(p.status == 0);
assert(p.stdout.hex() == "410042");

println("string-nul: ok");
''')

# Add to fast semantic gate.
rep('tests/fast.sh',
'''suites=(operators ranges hygiene environment hashability callables grammar layout ergonomics)''',
'''suites=(operators ranges hygiene environment hashability callables grammar layout ergonomics string-nul)''')

# Document representation decision as an implementation checkpoint, not final Unicode policy.
p=Path('ROADMAP.md'); s=p.read_text(); marker='## M0 — semantic hardening' if '## M0 — semantic hardening' in s else None
# ROADMAP currently uses narrative headings; append a short invariant if absent.
if 'Embedded U+0000 is a required reference-implementation conformance case' not in s:
    s += '''\n\n## Reference implementation fidelity rule\n\nEmbedded U+0000 is a required reference-implementation conformance case. Bash's inability to hold a NUL byte in a shell variable is an implementation detail, never a BLisp language restriction. The Bash runtime uses an encoded backing representation for strings that cannot be losslessly materialized in a shell variable; host APIs that themselves forbid NUL may reject such values at that boundary.\n'''
    p.write_text(s)
