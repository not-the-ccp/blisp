#!/usr/bin/env bash
# Runtime + interpreter core for BLisp, a small Lisp implemented in Bash.
# Uses global RET for function results to avoid command-substitution subshells.

# Value heap.
declare -Ag BL_TYPE=() BL_A=() BL_B=() BL_C=()
# Generic object/property heap layered on top of the value heap.  Properties may
# live on objects, arrays, functions, or any other allocated value.
declare -Ag BL_PROP=() BL_PROTO=() BL_KEY_COUNT=() BL_KEY_AT=() BL_ARR_LEN=()
# Bytes are stored byte-by-byte because Bash variables cannot contain NUL.
declare -Ag BL_BYTES_LEN=() BL_BYTE_AT=()
# Strings are semantically valid Unicode text. Ordinary strings may keep a raw
# Bash fast-path, but strings that Bash cannot represent losslessly (notably
# embedded U+0000) use canonical lowercase UTF-8 hex in BL_STR_HEX. Runtime
# code must use the helpers below rather than assuming BL_A is the string.
declare -Ag BL_STR_HEX=()
BL_OBJECT_PROTO=nil
BL_ARRAY_PROTO=nil
BL_FUNCTION_PROTO=nil
BL_STRING_PROTO=nil
BL_BYTES_PROTO=nil
BL_TCP_PROTO=nil
BL_FILE_PROTO=nil
BL_PROCESS_HANDLE_PROTO=nil
BL_SEQ=0
BL_GENSYM_SEQ=0
BL_GC_LAST_SEQ=0
BL_GC_RUNNING=0
RET=
BL_FLOW=
BL_FLOW_VALUE=nil

bl_alloc() {
  ((++BL_SEQ)) || true
  RET="v$BL_SEQ"
}

bl_make_nil() { RET="nil"; }
bl_make_bool() { [[ $1 == 0 || $1 == false || -z $1 ]] && RET="false" || RET="true"; }
bl_make_int() { bl_alloc; BL_TYPE[$RET]=int; BL_A[$RET]=$1; }

# Convert a Bash-held UTF-8 byte string to canonical hex without depending on
# locale character semantics. Bash cannot hold NUL, so this helper is only for
# already-materializable host text.
bl_text_to_utf8_hex() {
  local s=$1 out= i c ord hx; local LC_ALL=C
  for ((i=0;i<${#s};++i)); do
    c=${s:i:1}; printf -v ord '%d' "'$c"; printf -v hx '%02x' "$ord"; out+=$hx
  done
  RET=$out
}

BL_UTF8_CP_COUNT=0
bl_utf8_validate_hex() {
  local hex=${1,,} n=${#1} i=0 count=0 b1 b2 b3 b4
  (( n % 2 == 0 )) && [[ $hex != *[!0-9a-f]* ]] || return 1
  while (( i < n )); do
    b1=$((16#${hex:i:2}))
    if (( b1 <= 0x7f )); then ((i+=2)) || true
    elif (( b1 >= 0xc2 && b1 <= 0xdf )); then
      (( i+4 <= n )) || return 1; b2=$((16#${hex:i+2:2})); (( b2>=0x80 && b2<=0xbf )) || return 1; ((i+=4)) || true
    elif (( b1 >= 0xe0 && b1 <= 0xef )); then
      (( i+6 <= n )) || return 1; b2=$((16#${hex:i+2:2})); b3=$((16#${hex:i+4:2}))
      (( b3>=0x80 && b3<=0xbf )) || return 1
      if (( b1 == 0xe0 )); then (( b2>=0xa0 && b2<=0xbf )) || return 1
      elif (( b1 == 0xed )); then (( b2>=0x80 && b2<=0x9f )) || return 1
      else (( b2>=0x80 && b2<=0xbf )) || return 1; fi
      ((i+=6)) || true
    elif (( b1 >= 0xf0 && b1 <= 0xf4 )); then
      (( i+8 <= n )) || return 1; b2=$((16#${hex:i+2:2})); b3=$((16#${hex:i+4:2})); b4=$((16#${hex:i+6:2}))
      (( b3>=0x80 && b3<=0xbf && b4>=0x80 && b4<=0xbf )) || return 1
      if (( b1 == 0xf0 )); then (( b2>=0x90 && b2<=0xbf )) || return 1
      elif (( b1 == 0xf4 )); then (( b2>=0x80 && b2<=0x8f )) || return 1
      else (( b2>=0x80 && b2<=0xbf )) || return 1; fi
      ((i+=8)) || true
    else return 1; fi
    ((count++)) || true
  done
  BL_UTF8_CP_COUNT=$count
}

BL_HEX_ZERO_AT=-1
bl_hex_find_zero_byte() {
  local hex=$1 i
  BL_HEX_ZERO_AT=-1
  for ((i=0;i<${#hex};i+=2)); do [[ ${hex:i:2} == 00 ]] && { BL_HEX_ZERO_AT=$i; return 0; }; done
  return 1
}
bl_hex_has_zero_byte() { bl_hex_find_zero_byte "$1"; }

bl_utf8_hex_to_text() {
  local hex=${1,,} out= i pair ch
  bl_hex_has_zero_byte "$hex" && return 1
  for ((i=0;i<${#hex};i+=2)); do pair=${hex:i:2}; printf -v ch '%b' "\x$pair"; out+=$ch; done
  RET=$out
}

bl_make_string_from_hex() {
  local hex=${1,,}
  bl_utf8_validate_hex "$hex" || { bl_raise_error encoding 'invalid UTF-8'; return; }
  bl_alloc; local out=$RET raw=
  BL_TYPE[$out]=string
  if bl_hex_has_zero_byte "$hex"; then BL_STR_HEX[$out]=$hex; BL_A[$out]=
  else bl_utf8_hex_to_text "$hex" || return; raw=$RET; BL_A[$out]=$raw; fi
  [[ $BL_STRING_PROTO != nil ]] && BL_PROTO[$out]=$BL_STRING_PROTO
  RET=$out
}

bl_make_string() {
  bl_text_to_utf8_hex "$1"; local hex=$RET
  bl_make_string_from_hex "$hex"
}

bl_string_hex() {
  local v=$1
  [[ ${BL_TYPE[$v]-} == string ]] || { printf 'BLisp: expected string, got ' >&2; bl_repr "$v" >&2; printf '\n' >&2; return 1; }
  if [[ -v 'BL_STR_HEX[$v]' ]]; then RET=${BL_STR_HEX[$v]}; else bl_text_to_utf8_hex "${BL_A[$v]}"; fi
}

# Materialize a string for a host API that itself requires a C/Bash string.
# U+0000 is supported by BLisp; only the host boundary rejects it where the
# underlying OS/Bash interface cannot represent it.
bl_string_value() {
  local v=$1
  bl_string_hex "$v" || return; local hex=$RET
  if bl_hex_has_zero_byte "$hex"; then echo 'BLisp: this host API cannot accept a string containing U+0000' >&2; return 1; fi
  if [[ ! -v 'BL_STR_HEX[$v]' ]]; then RET=${BL_A[$v]}; return; fi
  bl_utf8_hex_to_text "$hex" || return
}

bl_string_write_fd() {
  local v=$1 fd=$2 i pair esc= chunk=0
  bl_string_hex "$v" || return; local hex=$RET
  for ((i=0;i<${#hex};i+=2)); do
    pair=${hex:i:2}; esc+="\\x$pair"; ((++chunk)) || true
    if ((chunk>=2048)); then printf '%b' "$esc" >&"$fd" || return; esc=; chunk=0; fi
  done
  [[ -z $esc ]] || printf '%b' "$esc" >&"$fd"
}
bl_string_write_path() { local v=$1 path=$2 fd; : > "$path" || return; exec {fd}>"$path" || return; bl_string_write_fd "$v" "$fd"; local st=$?; exec {fd}>&-; return $st; }

bl_utf8_hex_offset_for_cp() {
  local hex=$1 target=$2 i=0 cp=0 n=${#1} b step
  (( target >= 0 )) || return 1
  while (( i < n && cp < target )); do
    b=$((16#${hex:i:2}))
    if ((b<=0x7f)); then step=2; elif ((b<=0xdf)); then step=4; elif ((b<=0xef)); then step=6; else step=8; fi
    ((i+=step, cp++)) || true
  done
  (( cp == target )) || return 1
  RET=$i
}
bl_string_cp_count() { bl_string_hex "$1" || return; bl_utf8_validate_hex "$RET" || return; bl_make_int "$BL_UTF8_CP_COUNT"; }
bl_string_slice_value() {
  local v=$1 start=$2 end=$3
  bl_string_hex "$v" || return; local hex=$RET
  bl_utf8_validate_hex "$hex" || return; local n=$BL_UTF8_CP_COUNT
  ((start<0)) && start=$((n+start)); ((end<0)) && end=$((n+end)); ((start<0)) && start=0; ((end>n)) && end=$n; ((end<start)) && end=$start
  bl_utf8_hex_offset_for_cp "$hex" "$start" || return; local a=$RET
  bl_utf8_hex_offset_for_cp "$hex" "$end" || return; local b=$RET
  bl_make_string_from_hex "${hex:a:b-a}"
}
bl_string_at_value() {
  local v=$1 idx=$2
  bl_string_hex "$v" || return; local hex=$RET
  bl_utf8_validate_hex "$hex" || return; local n=$BL_UTF8_CP_COUNT
  ((idx>=0 && idx<n)) || { bl_make_string ''; return; }
  bl_utf8_hex_offset_for_cp "$hex" "$idx" || return; local a=$RET
  bl_utf8_hex_offset_for_cp "$hex" "$((idx+1))" || return; local b=$RET
  bl_make_string_from_hex "${hex:a:b-a}"
}
bl_string_index_of_values() {
  local sv=$1 nv=$2
  bl_string_hex "$sv" || return; local h=$RET
  bl_string_hex "$nv" || return; local needle=$RET
  [[ -n $needle ]] || { bl_make_int 0; return; }
  local off=0 cp=0 n=${#h} b step
  while ((off<=n-${#needle})); do
    if [[ ${h:off:${#needle}} == "$needle" ]]; then bl_make_int "$cp"; return; fi
    ((off<n)) || break
    b=$((16#${h:off:2})); if ((b<=0x7f)); then step=2; elif ((b<=0xdf)); then step=4; elif ((b<=0xef)); then step=6; else step=8; fi
    ((off+=step, cp++)) || true
  done
  bl_make_int -1
}

bl_make_bytes() {
  local -a xs=("$@")
  bl_alloc; local out=$RET i b
  BL_TYPE[$out]=bytes; BL_BYTES_LEN[$out]=${#xs[@]}; [[ $BL_BYTES_PROTO != nil ]] && BL_PROTO[$out]=$BL_BYTES_PROTO
  for ((i=0;i<${#xs[@]};++i)); do
    b=${xs[i]}
    [[ $b =~ ^[0-9]+$ ]] && (( b >= 0 && b <= 255 )) || { echo 'BLisp: byte must be an integer in 0..255' >&2; return 1; }
    BL_BYTE_AT["$out|$i"]=$b
  done
  RET=$out
}
bl_make_bytes_from_hex() {
  local hex=${1//[[:space:]]/} i pair; local -a xs=()
  (( ${#hex} % 2 == 0 )) || { echo 'BLisp: invalid byte hex literal' >&2; return 1; }
  [[ $hex =~ ^[0-9A-Fa-f]*$ ]] || { echo 'BLisp: invalid byte hex literal' >&2; return 1; }
  for ((i=0;i<${#hex};i+=2)); do pair=${hex:i:2}; xs+=("$((16#$pair))"); done
  bl_make_bytes "${xs[@]}"
}
bl_make_symbol() { bl_alloc; BL_TYPE[$RET]=symbol; BL_A[$RET]=$1; }
# Generated symbols carry an identity source syntax cannot produce.  BL_C is a
# debug spelling only; environment lookup/equality/hash use BL_A, so no source
# identifier can capture or be captured by a generated binding.
bl_make_gensym() {
  local debug=${1:-generated}
  ((++BL_GENSYM_SEQ)) || true
  bl_alloc; BL_TYPE[$RET]=symbol
  BL_A[$RET]=$'\x1f'"g$BL_GENSYM_SEQ"
  BL_C[$RET]=$debug
}
bl_cons() { local a=$1 b=$2; bl_alloc; BL_TYPE[$RET]=cons; BL_A[$RET]=$a; BL_B[$RET]=$b; }
# Every native callable kind is allocated through one initializer.  The
# Function-prototype attachment is therefore an invariant of callable creation,
# not something individual interpreter/compiler paths have to remember.
bl_init_callable() {
  local v=$1 type=$2
  BL_TYPE[$v]=$type
  [[ $BL_FUNCTION_PROTO != nil ]] && BL_PROTO[$v]=$BL_FUNCTION_PROTO
}
bl_make_builtin() { local name=$1 mode=${2:-plain}; bl_alloc; local v=$RET; bl_init_callable "$v" builtin; BL_A[$v]=$name; BL_C[$v]=$mode; RET=$v; }
bl_make_closure() { local fn=$1 env=$2 params=$3; bl_alloc; local v=$RET; bl_init_callable "$v" closure; BL_A[$v]=$fn; BL_B[$v]=$env; BL_C[$v]=$params; RET=$v; }
bl_make_compiled() { local fn=$1 env=$2; bl_alloc; local v=$RET; bl_init_callable "$v" compiled; BL_A[$v]=$fn; BL_B[$v]=$env; RET=$v; }
bl_make_object() { local proto=${1:-$BL_OBJECT_PROTO}; bl_alloc; BL_TYPE[$RET]=object; BL_PROTO[$RET]=$proto; BL_KEY_COUNT[$RET]=0; }
bl_make_array() {
  local -a xs=("$@")
  bl_alloc; local out=$RET i
  BL_TYPE[$out]=array; BL_PROTO[$out]=$BL_ARRAY_PROTO; BL_KEY_COUNT[$out]=0; BL_ARR_LEN[$out]=0
  for ((i=0;i<${#xs[@]};++i)); do bl_prop_set_key "$out" "$i" "${xs[i]}"; done
  RET=$out
}
bl_make_bound() { local fn=$1 thisv=$2 args=$3; bl_alloc; local v=$RET; bl_init_callable "$v" bound; BL_A[$v]=$fn; BL_B[$v]=$thisv; BL_C[$v]=$args; RET=$v; }

bl_typeof() {
  case $1 in
    nil) RET=nil ;;
    true|false) RET=bool ;;
    *) RET=${BL_TYPE[$1]-invalid} ;;
  esac
}

bl_truthy() { [[ $1 != false && $1 != nil ]]; }

bl_int_value() {
  local v=$1
  [[ ${BL_TYPE[$v]-} == int ]] || { printf 'BLisp: expected integer, got ' >&2; bl_repr "$v" >&2; printf '\n' >&2; return 1; }
  RET=${BL_A[$v]}
}

bl_symbol_name() {
  local v=$1
  [[ ${BL_TYPE[$v]-} == symbol ]] || { printf 'BLisp: expected symbol\n' >&2; return 1; }
  RET=${BL_A[$v]}
}

bl_list_from_array() {
  local -a xs=("$@")
  local out=nil i
  for ((i=${#xs[@]}-1; i>=0; --i)); do
    bl_cons "${xs[i]}" "$out"; out=$RET
  done
  RET=$out
}

bl_list_to_array() {
  local cur=$1
  BL_LIST_RESULT=()
  while [[ $cur != nil ]]; do
    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: expected proper list' >&2; return 1; }
    BL_LIST_RESULT+=("${BL_A[$cur]}")
    cur=${BL_B[$cur]}
  done
}

declare -ag BL_LIST_RESULT=()

# Environment heap.
declare -Ag BL_ENV_PARENT=() BL_ENV_BIND=() BL_ENV_CONST=()
BL_ENV_SEQ=0
BL_GLOBAL_ENV=

bl_env_new() {
  local parent=${1:-}
  ((++BL_ENV_SEQ)) || true
  RET="e$BL_ENV_SEQ"
  BL_ENV_PARENT[$RET]=$parent
}

bl_env_define() {
  local env=$1 name=$2 value=$3
  BL_ENV_BIND["$env|$name"]=$value
  RET=$value
}

bl_env_define_const() {
  local env=$1 name=$2 value=$3
  BL_ENV_BIND["$env|$name"]=$value
  BL_ENV_CONST["$env|$name"]=1
  RET=$value
}

bl_env_lookup() {
  local env=$1 name=$2 key
  while [[ -n $env ]]; do
    key="$env|$name"
    if [[ -v 'BL_ENV_BIND[$key]' ]]; then RET=${BL_ENV_BIND[$key]}; return 0; fi
    env=${BL_ENV_PARENT[$env]-}
  done
  echo "BLisp: unbound symbol: $name" >&2
  return 1
}

bl_env_set() {
  local env=$1 name=$2 value=$3 key
  while [[ -n $env ]]; do
    key="$env|$name"
    if [[ -v 'BL_ENV_BIND[$key]' ]]; then
      [[ ${BL_ENV_CONST[$key]-0} == 0 ]] || { echo "BLisp: cannot assign to const binding: $name" >&2; return 1; }
      BL_ENV_BIND[$key]=$value; RET=$value; return 0
    fi
    env=${BL_ENV_PARENT[$env]-}
  done
  echo "BLisp: cannot set! unbound symbol: $name" >&2
  return 1
}

# Printer.
bl_escape_string_value() {
  local v=$1 i pair out= ch
  bl_string_hex "$v" || return; local hex=$RET
  for ((i=0;i<${#hex};i+=2)); do
    pair=${hex:i:2}
    case $pair in
      00) out+='\0' ;; 09) out+='\t' ;; 0a) out+='\n' ;; 0d) out+='\r' ;;
      22) out+='\"' ;; 5c) out+='\\' ;;
      *) printf -v ch '%b' "\x$pair"; out+=$ch ;;
    esac
  done
  RET=$out
}

bl_repr() {
  local v=$1 cur first=1
  case $v in
    nil|true|false) printf '%s' "$v"; return ;;
  esac
  case ${BL_TYPE[$v]-invalid} in
    int|float) printf '%s' "${BL_A[$v]}" ;;
    bytes)
      printf 'b['; local __bi __bn=${BL_BYTES_LEN[$v]-0}
      for ((__bi=0;__bi<__bn;++__bi)); do ((__bi)) && printf ' '; printf '%02x' "${BL_BYTE_AT["$v|$__bi"]}"; done
      printf ']'
      ;;
    string) bl_escape_string_value "$v"; printf '"%s"' "$RET" ;;
    symbol)
      if [[ -n ${BL_C[$v]-} ]]; then printf '#<generated:%s>' "${BL_C[$v]}"
      else printf '%s' "${BL_A[$v]}"; fi
      ;;
    builtin) printf '<builtin %s>' "${BL_A[$v]}" ;;
    closure|compiled|bound) printf '<function>' ;;
    range)
      if [[ ${BL_C[$v]-0} == 1 ]]; then printf '%s..%s' "${BL_A[$v]}" "${BL_B[$v]}"; else printf '%s..<%s' "${BL_A[$v]}" "${BL_B[$v]}"; fi
      ;;
    array)
      printf '['; local __i __n=${BL_ARR_LEN[$v]-0}
      for ((__i=0;__i<__n;++__i)); do ((__i)) && printf ', '; bl_prop_get_key "$v" "$__i"; bl_repr "$RET"; done
      printf ']'
      ;;
    object)
      printf '{'; local __i __n=${BL_KEY_COUNT[$v]-0} __k
      for ((__i=0;__i<__n;++__i)); do ((__i)) && printf ', '; __k=${BL_KEY_AT["$v|$__i"]}; printf '%s: ' "$__k"; bl_prop_get_key "$v" "$__k"; bl_repr "$RET"; done
      printf '}'
      ;;
    cons)
      printf '('
      cur=$v
      while [[ ${BL_TYPE[$cur]-} == cons ]]; do
        (( first )) || printf ' '
        bl_repr "${BL_A[$cur]}"
        first=0
        cur=${BL_B[$cur]}
      done
      if [[ $cur != nil ]]; then printf ' . '; bl_repr "$cur"; fi
      printf ')'
      ;;
    *) printf '<invalid:%s>' "$v" ;;
  esac
}

bl_display() {
  local v=$1
  if [[ ${BL_TYPE[$v]-} == string ]]; then bl_string_write_fd "$v" 1; else bl_repr "$v"; fi
}

# Lexer/parser. Tokens are stored as strings; strings are prefixed S:, symbols Y:.
declare -ag BL_TOKENS=()
BL_TPOS=0

bl_lex() {
  local src=$1 i=0 n=${#1} c tok buf esc hx
  BL_TOKENS=()
  while (( i < n )); do
    c=${src:i:1}
    case $c in
      ' '|$'\t'|$'\r'|$'\n') ((i++)) || true ;;
      ';') while (( i<n )) && [[ ${src:i:1} != $'\n' ]]; do ((i++)) || true; done ;;
      '('|')') BL_TOKENS+=("$c"); ((i++)) || true ;;
      "'") BL_TOKENS+=("'"); ((i++)) || true ;;
      '"')
        ((i++)) || true; buf=
        while (( i<n )); do
          c=${src:i:1}; ((i++)) || true
          if [[ $c == '"' ]]; then break; fi
          if [[ $c == '\' ]]; then
            (( i<n )) || { echo 'BLisp: unterminated string escape' >&2; return 1; }
            esc=${src:i:1}; ((i++)) || true
            case $esc in
              n) buf+=0a;; t) buf+=09;; r) buf+=0d;; 0) buf+=00;; '"') buf+=22;; '\') buf+=5c;;
              *) bl_text_to_utf8_hex "$esc"; buf+=$RET;;
            esac
          else bl_text_to_utf8_hex "$c"; buf+=$RET; fi
        done
        [[ $c == '"' ]] || { echo 'BLisp: unterminated string' >&2; return 1; }
        BL_TOKENS+=("H:$buf")
        ;;
      *)
        buf=
        while (( i<n )); do
          c=${src:i:1}
          [[ $c == ' ' || $c == $'\t' || $c == $'\r' || $c == $'\n' || $c == '(' || $c == ')' || $c == "'" || $c == ';' ]] && break
          buf+="$c"; ((i++)) || true
        done
        BL_TOKENS+=("Y:$buf")
        ;;
    esac
  done
  BL_TPOS=0
}

bl_parse_one() {
  (( BL_TPOS < ${#BL_TOKENS[@]} )) || { echo 'BLisp: unexpected EOF' >&2; return 1; }
  local tok=${BL_TOKENS[BL_TPOS]}; ((BL_TPOS++)) || true
  case $tok in
    '(')
      local -a items=()
      while :; do
        (( BL_TPOS < ${#BL_TOKENS[@]} )) || { echo 'BLisp: missing )' >&2; return 1; }
        [[ ${BL_TOKENS[BL_TPOS]} == ')' ]] && { ((BL_TPOS++)) || true; break; }
        bl_parse_one || return; items+=("$RET")
      done
      bl_list_from_array "${items[@]}"
      ;;
    ')') echo 'BLisp: unexpected )' >&2; return 1 ;;
    "'")
      bl_parse_one || return
      local q=$RET
      bl_make_symbol quote; local qs=$RET
      bl_cons "$q" nil; local tail=$RET
      bl_cons "$qs" "$tail"
      ;;
    H:*) bl_make_string_from_hex "${tok:2}" ;;
    S:*) bl_make_string "${tok:2}" ;;
    Y:*)
      local atom=${tok:2}
      case $atom in
        nil) RET=nil ;;
        true|"#t") RET=true ;;
        false|"#f") RET=false ;;
        -[0-9]*|[0-9]*)
          if [[ $atom =~ ^-?[0-9]+$ ]]; then bl_make_int "$atom"; elif [[ $atom =~ ^-?[0-9]*\.[0-9]+([eE][-+]?[0-9]+)?$ || $atom =~ ^-?[0-9]+[eE][-+]?[0-9]+$ ]]; then bl_make_float "$atom"; else bl_make_symbol "$atom"; fi
          ;;
        *) bl_make_symbol "$atom" ;;
      esac
      ;;
  esac
}

declare -ag BL_FORMS=()
bl_parse_all() {
  bl_lex "$1" || return
  BL_FORMS=()
  while (( BL_TPOS < ${#BL_TOKENS[@]} )); do bl_parse_one || return; BL_FORMS+=("$RET"); done
}

# Helpers for AST lists.
bl_nth() {
  local cur=$1 n=$2 i
  for ((i=0; i<n; ++i)); do [[ ${BL_TYPE[$cur]-} == cons ]] || return 1; cur=${BL_B[$cur]}; done
  [[ ${BL_TYPE[$cur]-} == cons ]] || return 1
  RET=${BL_A[$cur]}
}

bl_rest() { [[ ${BL_TYPE[$1]-} == cons ]] || return 1; RET=${BL_B[$1]}; }

# Evaluator.
bl_eval_quasiquote() {
  local v=$1 env=$2
  case $v in nil|true|false) RET=$v; return;; esac
  case ${BL_TYPE[$v]-} in
    cons)
      local h=${BL_A[$v]} d=${BL_B[$v]}
      if [[ ${BL_TYPE[$h]-} == symbol && ${BL_A[$h]} == unquote ]]; then
        bl_nth "$d" 0 || { echo 'BLisp: unquote expects expression' >&2; return 1; }
        bl_eval "$RET" "$env"; return
      fi
      bl_eval_quasiquote "$h" "$env" || return; local qh=$RET
      bl_eval_quasiquote "$d" "$env" || return; local qd=$RET
      bl_cons "$qh" "$qd" ;;
    *) RET=$v ;;
  esac
}

bl_eval_sequence() {
  local forms=$1 env=$2 cur
  cur=$forms
  RET=nil
  while [[ $cur != nil ]]; do
    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: malformed body' >&2; return 1; }
    bl_eval "${BL_A[$cur]}" "$env" || return
    [[ -n $BL_FLOW ]] && return 0
    cur=${BL_B[$cur]}
  done
}

bl_bind_params() {
  local env=$1 params=$2; shift 2
  local -a args=("$@")
  local scan=$params required=0 tail

  # Validate the complete parameter shape and arity before installing
  # any bindings. This keeps failed calls atomic and gives the
  # interpreter/compiler one deterministic diagnostic contract.
  while [[ ${BL_TYPE[$scan]-} == cons ]]; do
    ((required++)) || true
    scan=${BL_B[$scan]}
  done
  tail=$scan
  if [[ $tail == nil ]]; then
    (( ${#args[@]} == required )) || {
      echo "BLisp: arity mismatch: expected $required, got ${#args[@]}" >&2
      return 1
    }
  else
    [[ ${BL_TYPE[$tail]-} == symbol ]] || { echo 'BLisp: malformed lambda parameter list' >&2; return 1; }
    (( ${#args[@]} >= required )) || {
      echo "BLisp: arity mismatch: expected at least $required, got ${#args[@]}" >&2
      return 1
    }
  fi

  local cur=$params i=0 namev
  while [[ ${BL_TYPE[$cur]-} == cons ]]; do
    namev=${BL_A[$cur]}
    [[ ${BL_TYPE[$namev]-} == symbol ]] || { echo 'BLisp: lambda parameter is not a symbol' >&2; return 1; }
    bl_env_define "$env" "${BL_A[$namev]}" "${args[i]}" >/dev/null
    ((i++)) || true
    cur=${BL_B[$cur]}
  done
  if [[ $cur == nil ]]; then RET=nil; return 0; fi

  local -a rest=("${args[@]:i}")
  bl_list_from_array "${rest[@]}"; local restv=$RET
  bl_env_define "$env" "${BL_A[$cur]}" "$restv" >/dev/null
  RET=$restv
}

bl_apply() {
  local fn=$1; shift
  bl_apply_this "$fn" nil "$@"
}

bl_apply_this() {
  local fn=$1 thisv=$2; shift 2
  case ${BL_TYPE[$fn]-invalid} in
    builtin)
      if [[ ${BL_C[$fn]-plain} == method ]]; then
        "bl_builtin_${BL_A[$fn]}" "$thisv" "$@"
      else
        "bl_builtin_${BL_A[$fn]}" "$@"
      fi
      ;;
    closure)
      bl_env_new "${BL_B[$fn]}"; local callenv=$RET
      bl_env_define "$callenv" this "$thisv" >/dev/null
      local packed params body
      packed=${BL_C[$fn]}; params=${packed%%|*}; body=${packed#*|}
      bl_bind_params "$callenv" "$params" "$@" || return
      local saved_flow=$BL_FLOW saved_flow_value=$BL_FLOW_VALUE
      BL_FLOW=; BL_FLOW_VALUE=nil
      bl_eval_sequence "$body" "$callenv" || return
      if [[ $BL_FLOW == return ]]; then RET=$BL_FLOW_VALUE; BL_FLOW=; BL_FLOW_VALUE=nil; fi
      [[ -z $BL_FLOW ]] || { echo "BLisp: $BL_FLOW used outside a loop" >&2; return 1; }
      # A function boundary consumes its own control flow, but not an outer one.
      [[ -z $saved_flow ]] || { BL_FLOW=$saved_flow; BL_FLOW_VALUE=$saved_flow_value; }
      ;;
    compiled)
      "${BL_A[$fn]}" "${BL_B[$fn]}" "$thisv" "$@"
      ;;
    bound)
      local target=${BL_A[$fn]} bound_this=${BL_B[$fn]} packed=${BL_C[$fn]}
      bl_list_to_array "$packed" || return
      local -a pre=("${BL_LIST_RESULT[@]}")
      bl_apply_this "$target" "$bound_this" "${pre[@]}" "$@"
      ;;
    *)
      if [[ $fn != nil && $fn != true && $fn != false && -n ${BL_TYPE[$fn]-} ]]; then
        bl_prop_get_key "$fn" __call__; local __call=$RET
        if [[ $__call != nil ]]; then bl_apply_this "$__call" "$fn" "$@"; return; fi
      fi
      echo 'BLisp: attempted to call non-function' >&2; return 1 ;;
  esac
}

bl_eval() {
  local expr=$1 env=$2 type
  type=${BL_TYPE[$expr]-}
  case $expr in nil|true|false) RET=$expr; return;; esac
  case $type in
    int|float|string|bytes|builtin|closure|compiled|bound|object|array) RET=$expr; return ;;
    symbol) bl_env_lookup "$env" "${BL_A[$expr]}"; return ;;
    cons) ;;
    *) echo "BLisp: invalid value $expr" >&2; return 1 ;;
  esac

  local head=${BL_A[$expr]} rest=${BL_B[$expr]} name
  if [[ ${BL_TYPE[$head]-} == symbol ]]; then
    name=${BL_A[$head]}
    case $name in
      quote)
        bl_nth "$rest" 0 || { echo 'BLisp: quote expects one argument' >&2; return 1; }; return ;;
      quasiquote)
        bl_nth "$rest" 0 || { echo 'BLisp: quasiquote expects one argument' >&2; return 1; }
        bl_eval_quasiquote "$RET" "$env"; return ;;
      eval)
        bl_nth "$rest" 0 || { echo 'BLisp: eval expects one argument' >&2; return 1; }
        bl_eval "$RET" "$env" || return
        local code=$RET; bl_eval "$code" "$env"; return ;;
      if)
        bl_nth "$rest" 0 || return 1; local cexpr=$RET
        bl_nth "$rest" 1 || return 1; local texpr=$RET
        if bl_nth "$rest" 2; then local fexpr=$RET; else local fexpr=nil; fi
        bl_eval "$cexpr" "$env" || return
        if bl_truthy "$RET"; then bl_eval "$texpr" "$env"; else bl_eval "$fexpr" "$env"; fi
        return ;;
      begin) bl_eval_sequence "$rest" "$env"; return ;;
      define)
        bl_nth "$rest" 0 || return 1; local target=$RET
        if [[ ${BL_TYPE[$target]-} == cons ]]; then
          local fnamev=${BL_A[$target]} params=${BL_B[$target]}
          [[ ${BL_TYPE[$fnamev]-} == symbol ]] || { echo 'BLisp: bad function definition' >&2; return 1; }
          bl_rest "$rest"; local body=$RET
          bl_make_closure interpreted "$env" "$params|$body"; local clos=$RET
          bl_env_define "$env" "${BL_A[$fnamev]}" "$clos"
        else
          [[ ${BL_TYPE[$target]-} == symbol ]] || { echo 'BLisp: define target must be symbol' >&2; return 1; }
          bl_nth "$rest" 1 || return 1; bl_eval "$RET" "$env" || return; bl_env_define "$env" "${BL_A[$target]}" "$RET"
        fi
        return ;;
      define-const)
        bl_nth "$rest" 0 || return 1; local cv=$RET
        [[ ${BL_TYPE[$cv]-} == symbol ]] || { echo 'BLisp: const target must be symbol' >&2; return 1; }
        bl_nth "$rest" 1 || return 1; bl_eval "$RET" "$env" || return; bl_env_define_const "$env" "${BL_A[$cv]}" "$RET"
        return ;;
      set!)
        bl_nth "$rest" 0 || return 1; local sv=$RET
        [[ ${BL_TYPE[$sv]-} == symbol ]] || { echo 'BLisp: set! target must be symbol' >&2; return 1; }
        bl_nth "$rest" 1 || return 1; bl_eval "$RET" "$env" || return; bl_env_set "$env" "${BL_A[$sv]}" "$RET"; return ;;
      lambda)
        bl_nth "$rest" 0 || return 1; local params=$RET
        bl_rest "$rest"; local body=$RET
        bl_make_closure interpreted "$env" "$params|$body"; return ;;
      let)
        bl_nth "$rest" 0 || return 1; local binds=$RET
        bl_rest "$rest"; local body=$RET
        local -a pnames=() vals=(); local bc=$binds pair
        while [[ $bc != nil ]]; do
          pair=${BL_A[$bc]}; bl_nth "$pair" 0 || return 1; pnames+=("$RET"); bl_nth "$pair" 1 || return 1; vals+=("$RET"); bc=${BL_B[$bc]}
        done
        local -a argv=(); local ve
        for ve in "${vals[@]}"; do bl_eval "$ve" "$env" || return; argv+=("$RET"); done
        bl_env_new "$env"; local letenv=$RET; local i
        for ((i=0;i<${#pnames[@]};++i)); do
          [[ ${BL_TYPE[${pnames[i]}]-} == symbol ]] || { echo 'BLisp: let binding name must be symbol' >&2; return 1; }
          bl_env_define "$letenv" "${BL_A[${pnames[i]}]}" "${argv[i]}" >/dev/null
        done
        bl_eval_sequence "$body" "$letenv"
        return ;;
      and)
        local ac=$rest; RET=true
        while [[ $ac != nil ]]; do bl_eval "${BL_A[$ac]}" "$env" || return; bl_truthy "$RET" || return 0; ac=${BL_B[$ac]}; done; return ;;
      or)
        local oc=$rest; RET=false
        while [[ $oc != nil ]]; do bl_eval "${BL_A[$oc]}" "$env" || return; bl_truthy "$RET" && return 0; oc=${BL_B[$oc]}; done; return ;;
      scope)
        bl_env_new "$env"; local scope_env=$RET
        bl_eval_sequence "$rest" "$scope_env"; return ;;
      while)
        bl_nth "$rest" 0 || { echo 'BLisp: while expects condition' >&2; return 1; }; local wcond=$RET
        bl_rest "$rest" || return 1; local wbody=$RET
        RET=nil
        while :; do
          bl_eval "$wcond" "$env" || return
          bl_truthy "$RET" || { RET=nil; break; }
          bl_eval_sequence "$wbody" "$env" || return
          case $BL_FLOW in
            return) return 0 ;;
            break) BL_FLOW=; BL_FLOW_VALUE=nil; RET=nil; break ;;
            continue) BL_FLOW=; BL_FLOW_VALUE=nil ;;
          esac
        done
        return ;;
      for-of)
        bl_nth "$rest" 0 || return 1; local fvar=$RET
        [[ ${BL_TYPE[$fvar]-} == symbol ]] || { echo 'BLisp: for-of variable must be symbol' >&2; return 1; }
        bl_nth "$rest" 1 || return 1; local fiter_expr=$RET
        bl_rest "$rest" || return 1; local __fr=$RET; bl_rest "$__fr" || return 1; local fbody=$RET
        bl_eval "$fiter_expr" "$env" || return
        bl_iter_begin "$RET" || return; local fit=$RET fv fenv
        while :; do
          bl_iter_next "$fit" || return; ((BL_ITER_DONE)) && break; fv=$RET
          bl_env_new "$env"; fenv=$RET; bl_env_define "$fenv" "${BL_A[$fvar]}" "$fv" >/dev/null
          bl_eval_sequence "$fbody" "$fenv" || return
          case $BL_FLOW in
            return) return 0 ;;
            break) BL_FLOW=; BL_FLOW_VALUE=nil; RET=nil; break ;;
            continue) BL_FLOW=; BL_FLOW_VALUE=nil ;;
          esac
        done
        return ;;
      for-c)
        bl_nth "$rest" 0 || return 1; local fcinit=$RET
        bl_nth "$rest" 1 || return 1; local fccond=$RET
        bl_nth "$rest" 2 || return 1; local fcstep=$RET
        bl_nth "$rest" 3 || return 1; local fcbody=$RET
        [[ $fcinit == nil ]] || { bl_eval "$fcinit" "$env" || return; }
        RET=nil
        while :; do
          [[ $fccond == true ]] || { bl_eval "$fccond" "$env" || return; bl_truthy "$RET" || { RET=nil; break; }; }
          bl_eval "$fcbody" "$env" || return
          case $BL_FLOW in
            return) return 0 ;;
            break) BL_FLOW=; BL_FLOW_VALUE=nil; RET=nil; break ;;
            continue) BL_FLOW=; BL_FLOW_VALUE=nil ;;
          esac
          [[ $fcstep == nil ]] || { bl_eval "$fcstep" "$env" || return; }
        done
        return ;;
      return)
        if [[ $rest == nil ]]; then RET=nil; else bl_nth "$rest" 0 || return 1; bl_eval "$RET" "$env" || return; fi
        BL_FLOW=return; BL_FLOW_VALUE=$RET; return ;;
      break) BL_FLOW=break; BL_FLOW_VALUE=nil; RET=nil; return ;;
      continue) BL_FLOW=continue; BL_FLOW_VALUE=nil; RET=nil; return ;;
    esac
  fi

  bl_eval "$head" "$env" || return; local fn=$RET
  local -a argv=(); local cur=$rest
  while [[ $cur != nil ]]; do
    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: improper call form' >&2; return 1; }
    bl_eval "${BL_A[$cur]}" "$env" || return; argv+=("$RET"); cur=${BL_B[$cur]}
  done
  bl_apply "$fn" "${argv[@]}"
}

# Object/array/prototype support.
bl_prop_key() {
  local v=$1
  case $v in true|false|nil) RET=$v; return;; esac
  case ${BL_TYPE[$v]-} in
    string)
      bl_string_hex "$v" || return; local __kh=$RET
      if [[ -v 'BL_STR_HEX[$v]' ]]; then RET=$'\x1e'"$__kh"
      else bl_utf8_hex_to_text "$__kh" || return; local __kr=$RET; if [[ $__kr == $'\x1e'* || $__kr == *'|'* ]]; then RET=$'\x1e'"$__kh"; else RET=$__kr; fi; fi ;;
    symbol|int) RET=${BL_A[$v]} ;;
    *) echo 'BLisp: property key must be string, symbol, or integer' >&2; return 1 ;;
  esac
}

bl_prop_set_key() {
  local obj=$1 key=$2 val=$3 slot
  if [[ ${BL_TYPE[$obj]-} == bytes && $key =~ ^[0-9]+$ ]]; then
    bl_int_value "$val" || return; local b=$RET n=${BL_BYTES_LEN[$obj]-0}
    (( b >= 0 && b <= 255 )) || { echo 'BLisp: byte assignment requires 0..255' >&2; return 1; }
    (( key >= 0 && key <= n )) || { echo 'BLisp: byte index out of bounds' >&2; return 1; }
    BL_BYTE_AT["$obj|$key"]=$b; (( key == n )) && BL_BYTES_LEN[$obj]=$((n+1)); RET=$val; return
  fi
  slot="$obj|$key"
  [[ $obj != nil && $obj != true && $obj != false && -n ${BL_TYPE[$obj]-} ]] || { echo 'BLisp: cannot set property on primitive' >&2; return 1; }
  if [[ ! -v 'BL_PROP[$slot]' ]]; then
    local n=${BL_KEY_COUNT[$obj]-0}; BL_KEY_AT["$obj|$n"]=$key; BL_KEY_COUNT[$obj]=$((n+1))
  fi
  BL_PROP[$slot]=$val
  if [[ ${BL_TYPE[$obj]-} == array && $key =~ ^[0-9]+$ ]]; then
    local n=${BL_ARR_LEN[$obj]-0}; (( key >= n )) && BL_ARR_LEN[$obj]=$((key+1))
  fi
  RET=$val
}

bl_prop_get_key() {
  local obj=$1 key=$2 cur slot
  if [[ ${BL_TYPE[$obj]-} == array && $key == length ]]; then bl_make_int "${BL_ARR_LEN[$obj]-0}"; return; fi
  if [[ ${BL_TYPE[$obj]-} == bytes && $key == length ]]; then bl_make_int "${BL_BYTES_LEN[$obj]-0}"; return; fi
  if [[ ${BL_TYPE[$obj]-} == bytes && $key =~ ^[0-9]+$ ]]; then local __bn=${BL_BYTES_LEN[$obj]-0}; if (( key>=0 && key<__bn )); then bl_make_int "${BL_BYTE_AT["$obj|$key"]}"; else RET=nil; fi; return; fi
  if [[ ${BL_TYPE[$obj]-} == string && $key == length ]]; then bl_string_cp_count "$obj"; return; fi
  if [[ ${BL_TYPE[$obj]-} == string && $key =~ ^[0-9]+$ ]]; then
    bl_string_hex "$obj" || return; local __sh=$RET; bl_utf8_validate_hex "$__sh" || return; local __sn=$BL_UTF8_CP_COUNT
    if (( key >= 0 && key < __sn )); then bl_string_at_value "$obj" "$key"; else RET=nil; fi; return
  fi
  if [[ ${BL_TYPE[$obj]-} == range ]]; then
    local __rs=${BL_A[$obj]} __re=${BL_B[$obj]} __ri=${BL_C[$obj]-0} __step=1 __len
    ((__rs > __re)) && __step=-1
    if ((__ri)); then __len=$(( (__re-__rs)*__step + 1 )); else __len=$(( (__re-__rs)*__step )); fi
    ((__len < 0)) && __len=0
    case $key in
      start) bl_make_int "$__rs"; return ;;
      end) bl_make_int "$__re"; return ;;
      step) bl_make_int "$__step"; return ;;
      inclusive) ((__ri)) && RET=true || RET=false; return ;;
      length) bl_make_int "$__len"; return ;;
    esac
    if [[ $key =~ ^[0-9]+$ ]]; then
      local __idx=$key
      if ((__idx < __len)); then bl_make_int "$((__rs + __idx*__step))"; else RET=nil; fi
      return
    fi
  fi
  case ${BL_TYPE[$obj]-} in builtin|closure|compiled|bound)
    case $key in
      # Constructor prototype objects are materialized lazily, but Function
      # behavior (`call`/`apply`/`bind`) is ordinary prototype lookup below.
      prototype) [[ -v 'BL_PROP["$obj|prototype"]' ]] || { bl_ensure_prototype "$obj"; return; };;
    esac
  esac
  cur=$obj
  while [[ $cur != nil && -n $cur ]]; do
    slot="$cur|$key"
    if [[ -v 'BL_PROP[$slot]' ]]; then RET=${BL_PROP[$slot]}; return 0; fi
    cur=${BL_PROTO[$cur]-nil}
  done
  RET=nil
}

bl_prop_has_key() {
  local obj=$1 key=$2 cur=$1
  while [[ $cur != nil && -n $cur ]]; do
    [[ -v 'BL_PROP["$cur|$key"]' ]] && { RET=true; return; }
    cur=${BL_PROTO[$cur]-nil}
  done
  RET=false
}

bl_prop_own_key() { [[ -v 'BL_PROP["$1|$2"]' ]] && RET=true || RET=false; }

bl_prop_delete_key() {
  local obj=$1 key=$2 slot
  slot="$obj|$key"
  if [[ -v 'BL_PROP[$slot]' ]]; then unset 'BL_PROP[$slot]'; RET=true; else RET=false; fi
}

bl_iter_begin() {
  local v=$1 fn it
  case ${BL_TYPE[$v]-} in
    array|bytes|string|cons|range)
      bl_alloc; local cur=$RET; BL_TYPE[$cur]=iterator; BL_A[$cur]=$v
      if [[ ${BL_TYPE[$v]} == cons ]]; then BL_B[$cur]=$v
      elif [[ ${BL_TYPE[$v]} == range ]]; then BL_B[$cur]=${BL_A[$v]}
      else BL_B[$cur]=0; fi
      RET=$cur ;;
    object|builtin|closure|compiled|bound)
      bl_prop_get_key "$v" __iter__; fn=$RET
      [[ $fn != nil ]] || { echo 'BLisp: value is not iterable' >&2; return 1; }
      bl_apply_this "$fn" "$v" || return; it=$RET
      case ${BL_TYPE[$it]-} in array|bytes|string|cons|range) bl_iter_begin "$it";; *) bl_prop_get_key "$it" next; [[ $RET != nil ]] || { echo 'BLisp: __iter__ result needs next()' >&2; return 1; }; RET=$it;; esac ;;
    *) [[ $v == nil ]] && { bl_alloc; local cur=$RET; BL_TYPE[$cur]=iterator; BL_A[$cur]=nil; BL_B[$cur]=0; RET=$cur; return; }; echo 'BLisp: value is not iterable' >&2; return 1 ;;
  esac
}
BL_ITER_DONE=0
bl_iter_next() {
  local it=$1 src idx fn step donev
  BL_ITER_DONE=0
  if [[ ${BL_TYPE[$it]-} == iterator ]]; then
    src=${BL_A[$it]}
    [[ $src != nil ]] || { BL_ITER_DONE=1; RET=nil; return; }
    case ${BL_TYPE[$src]-} in
      array) idx=${BL_B[$it]}; if ((idx>=${BL_ARR_LEN[$src]-0})); then BL_ITER_DONE=1; RET=nil; else bl_prop_get_key "$src" "$idx"; BL_B[$it]=$((idx+1)); fi ;;
      bytes) idx=${BL_B[$it]}; if ((idx>=${BL_BYTES_LEN[$src]-0})); then BL_ITER_DONE=1; RET=nil; else bl_make_int "${BL_BYTE_AT["$src|$idx"]}"; BL_B[$it]=$((idx+1)); fi ;;
      string) idx=${BL_B[$it]}; bl_string_hex "$src" || return; local __sh=$RET; bl_utf8_validate_hex "$__sh" || return; if ((idx>=BL_UTF8_CP_COUNT)); then BL_ITER_DONE=1; RET=nil; else bl_string_at_value "$src" "$idx"; BL_B[$it]=$((idx+1)); fi ;;
      range)
        idx=${BL_B[$it]}; local __end=${BL_B[$src]} __inc=${BL_C[$src]-0} __step=1
        ((${BL_A[$src]} > __end)) && __step=-1
        if ((__step > 0)); then
          if ((__inc ? idx > __end : idx >= __end)); then BL_ITER_DONE=1; RET=nil; return; fi
        else
          if ((__inc ? idx < __end : idx <= __end)); then BL_ITER_DONE=1; RET=nil; return; fi
        fi
        bl_make_int "$idx"; BL_B[$it]=$((idx+__step)) ;;
      cons) local cur=${BL_B[$it]}; if [[ $cur == nil ]]; then BL_ITER_DONE=1; RET=nil; else [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: improper list is not iterable' >&2; return 1; }; RET=${BL_A[$cur]}; BL_B[$it]=${BL_B[$cur]}; fi ;;
      *) echo 'BLisp: corrupt native iterator' >&2; return 1 ;;
    esac
    return
  fi
  bl_prop_get_key "$it" next; fn=$RET; [[ $fn != nil ]] || { echo 'BLisp: iterator has no next()' >&2; return 1; }
  bl_apply_this "$fn" "$it" || return; step=$RET
  [[ ${BL_TYPE[$step]-} == object ]] || { echo 'BLisp: iterator next() must return {done,value}' >&2; return 1; }
  bl_prop_get_key "$step" done; donev=$RET
  if bl_truthy "$donev"; then
    BL_ITER_DONE=1
    RET=nil
  else
    bl_prop_get_key "$step" value
    BL_ITER_DONE=0
  fi
}
bl_iter_values() {
  local v=$1 it
  local -a out=()
  bl_iter_begin "$v" || return; it=$RET
  while :; do
    bl_iter_next "$it" || return
    ((BL_ITER_DONE)) && break
    out+=("$RET")
  done
  BL_ITER_RESULT=("${out[@]}")
  RET=$v
}
declare -ag BL_ITER_RESULT=()

bl_value_to_string() {
  local v=$1 fn tmp
  case ${BL_TYPE[$v]-} in
    string) RET=$v; return ;;
    int|float) bl_make_string "${BL_A[$v]}"; return ;;
    symbol) bl_make_string "${BL_C[$v]-${BL_A[$v]}}"; return ;;
    object|array|bytes|builtin|closure|compiled|bound)
      bl_prop_get_key "$v" __str__; fn=$RET
      if [[ $fn != nil ]]; then
        bl_apply_this "$fn" "$v" || return
        [[ ${BL_TYPE[$RET]-} == string ]] || { echo 'BLisp: __str__ must return string' >&2; return 1; }
        return
      fi ;;
  esac
  case $v in nil|true|false) bl_make_string "$v"; return;; esac
  tmp=$(bl_repr "$v"); bl_make_string "$tmp"
}

bl_builtin_js_add() { bl_builtin_add "$@"; }

bl_builtin_typeof() {
  bl_expect_arity $# 1 typeof || return
  local t
  case $1 in nil) t=object;; true|false) t=boolean;; *)
    case ${BL_TYPE[$1]-} in int|float) t=number;; string) t=string;; bytes) t=bytes;; builtin|closure|compiled|bound) t=function;; object|array|cons|range) t=object;; symbol) t=symbol;; *) t=invalid;; esac
    ;;
  esac
  bl_make_string "$t"
}

bl_make_range() {
  local start=$1 end=$2 inclusive=$3
  bl_alloc; local v=$RET
  BL_TYPE[$v]=range; BL_A[$v]=$start; BL_B[$v]=$end; BL_C[$v]=$inclusive
  BL_PROTO[$v]=${BL_OBJECT_PROTO:-nil}
  RET=$v
}

bl_builtin_range_common() {
  local inclusive=$1; shift
  bl_expect_arity $# 2 range || return
  bl_int_value "$1" || return; local a=$RET
  bl_int_value "$2" || return; local b=$RET
  bl_make_range "$a" "$b" "$inclusive"
}
bl_builtin_range_inclusive() { bl_builtin_range_common 1 "$@"; }
bl_builtin_range_exclusive() { bl_builtin_range_common 0 "$@"; }
bl_builtin_len() {
  bl_expect_arity $# 1 len || return
  local v=$1 n=0 cur fn
  case ${BL_TYPE[$v]-} in
    string) bl_string_cp_count "$v" ;;
    bytes) bl_make_int "${BL_BYTES_LEN[$v]-0}" ;;
    array) bl_make_int "${BL_ARR_LEN[$v]-0}" ;;
    range)
      local __a=${BL_A[$v]} __b=${BL_B[$v]} __step=1 __n
      ((__a > __b)) && __step=-1
      if [[ ${BL_C[$v]-0} == 1 ]]; then __n=$(( (__b-__a)*__step + 1 )); else __n=$(( (__b-__a)*__step )); fi
      ((__n < 0)) && __n=0
      bl_make_int "$__n" ;;
    cons) cur=$v; while [[ $cur != nil ]]; do [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: len on improper list' >&2; return 1; }; ((n++)) || true; cur=${BL_B[$cur]}; done; bl_make_int "$n" ;;
    object|builtin|closure|compiled|bound)
      bl_prop_get_key "$v" __len__; fn=$RET
      if [[ $fn != nil ]]; then bl_apply_this "$fn" "$v" || return; [[ ${BL_TYPE[$RET]-} == int ]] || { echo 'BLisp: __len__ must return int' >&2; return 1; }; return; fi
      local i k count=${BL_KEY_COUNT[$v]-0}; n=0
      for ((i=0;i<count;++i)); do k=${BL_KEY_AT["$v|$i"]-}; [[ -n $k && -v 'BL_PROP["$v|$k"]' ]] && ((n++)) || true; done
      bl_make_int "$n" ;;
    *) [[ $v == nil ]] && { bl_make_int 0; return; }; echo 'BLisp: len unsupported for value' >&2; return 1 ;;
  esac
}
bl_builtin_type_name() {
  bl_expect_arity $# 1 type || return
  local t
  case $1 in nil) t=nil;; true|false) t=bool;; *)
    case ${BL_TYPE[$1]-invalid} in
      int) t=int;; float) t=float;; string) t=string;; bytes) t=bytes;; symbol) t=symbol;; cons) t=list;; array) t=array;; range) t=range;; object) t=object;; builtin|closure|compiled|bound) t=function;; *) t=invalid;; esac
  esac
  bl_make_string "$t"
}

bl_builtin_object() {
  (( $# % 2 == 0 )) || { echo 'BLisp: object expects key/value pairs' >&2; return 1; }
  bl_make_object "$BL_OBJECT_PROTO"; local obj=$RET k
  while (($#)); do bl_prop_key "$1" || return; k=$RET; bl_prop_set_key "$obj" "$k" "$2" || return; shift 2; done
  RET=$obj
}
bl_builtin_array() { bl_make_array "$@"; }
bl_builtin_get() { bl_expect_arity $# 2 get || return; bl_prop_key "$2" || return; local k=$RET; bl_prop_get_key "$1" "$k"; }
bl_builtin_set_prop() { bl_expect_arity $# 3 set-prop! || return; bl_prop_key "$2" || return; local k=$RET; bl_prop_set_key "$1" "$k" "$3"; }
bl_builtin_delete_prop() { bl_expect_arity $# 2 delete-prop! || return; bl_prop_key "$2" || return; local k=$RET; bl_prop_delete_key "$1" "$k"; }
bl_builtin_has_prop() { bl_expect_arity $# 2 has-prop? || return; bl_prop_key "$2" || return; local k=$RET; bl_prop_has_key "$1" "$k"; }
bl_builtin_own_prop() { bl_expect_arity $# 2 own-prop? || return; bl_prop_key "$2" || return; local k=$RET; bl_prop_own_key "$1" "$k"; }
bl_builtin_get_proto() { bl_expect_arity $# 1 get-proto || return; RET=${BL_PROTO[$1]-nil}; }
bl_builtin_set_proto() {
  bl_expect_arity $# 2 set-proto! || return
  local obj=$1 proto=$2 cur=$2
  [[ $proto == nil || ( $proto != true && $proto != false && -n ${BL_TYPE[$proto]-} ) ]] || { echo 'BLisp: prototype must be an allocated value or nil' >&2; return 1; }
  while [[ $cur != nil ]]; do [[ $cur == "$obj" ]] && { echo 'BLisp: prototype cycle' >&2; return 1; }; cur=${BL_PROTO[$cur]-nil}; done
  BL_PROTO[$obj]=$proto; RET=$obj
}
bl_builtin_keys() {
  bl_expect_arity $# 1 keys || return
  local obj=$1 n=${BL_KEY_COUNT[$1]-0} i k; local -a vals=()
  for ((i=0;i<n;++i)); do k=${BL_KEY_AT["$obj|$i"]}; [[ -v 'BL_PROP["$obj|$k"]' ]] || continue; if [[ $k == $'\x1e'* ]]; then bl_make_string_from_hex "${k:1}"; else bl_make_string "$k"; fi; vals+=("$RET"); done
  bl_make_array "${vals[@]}"
}
bl_builtin_object_merge() {
  bl_make_object "$BL_OBJECT_PROTO"; local out=$RET src count i k
  for src in "$@"; do
    case ${BL_TYPE[$src]-} in object|array|builtin|closure|compiled|bound) ;; *) echo 'BLisp: object spread expects property-bearing values' >&2; return 1;; esac
    count=${BL_KEY_COUNT[$src]-0}
    for ((i=0;i<count;++i)); do
      k=${BL_KEY_AT["$src|$i"]-}; [[ -n $k && -v 'BL_PROP["$src|$k"]' ]] || continue
      bl_prop_set_key "$out" "$k" "${BL_PROP["$src|$k"]}" >/dev/null
    done
  done
  RET=$out
}
bl_builtin_to_array() { bl_expect_arity $# 1 toArray || return; bl_iter_values "$1" || return; bl_make_array "${BL_ITER_RESULT[@]}"; }
bl_builtin_to_list() { bl_expect_arity $# 1 toList || return; bl_iter_values "$1" || return; bl_list_from_array "${BL_ITER_RESULT[@]}"; }
# Expose the iterator protocol itself so userland can build lazy combinators
# without materializing sources. nextItem intentionally returns the protocol
# step object instead of throwing at exhaustion.
bl_builtin_iterator() { bl_expect_arity $# 1 iterator || return; bl_iter_begin "$1"; }
bl_builtin_next_item() {
  bl_expect_arity $# 1 nextItem || return
  local it=$1 value
  bl_iter_next "$it" || return
  local done=$BL_ITER_DONE
  value=$RET
  bl_make_object "$BL_OBJECT_PROTO"; local step=$RET
  if ((done)); then
    bl_prop_set_key "$step" done true >/dev/null
    bl_prop_set_key "$step" value nil >/dev/null
  else
    bl_prop_set_key "$step" done false >/dev/null
    bl_prop_set_key "$step" value "$value" >/dev/null
  fi
  RET=$step
}

bl_builtin_object_create() { bl_expect_arity $# 1 Object.create || return; [[ $1 == nil || ( $1 != true && $1 != false && -n ${BL_TYPE[$1]-} ) ]] || { echo 'BLisp: Object.create prototype must be object/function/nil' >&2; return 1; }; bl_make_object "$1"; }
bl_builtin_object_is_array() { bl_expect_arity $# 1 Array.isArray || return; [[ ${BL_TYPE[$1]-} == array ]] && RET=true || RET=false; }
bl_builtin_has_own_method() { local thisv=$1; shift; bl_expect_arity $# 1 hasOwnProperty || return; bl_prop_key "$1" || return; local k=$RET; bl_prop_own_key "$thisv" "$k"; }

bl_ensure_prototype() {
  local fn=$1 slot="$1|prototype"
  if [[ -v 'BL_PROP[$slot]' && ${BL_TYPE[${BL_PROP[$slot]}]-} == object ]]; then RET=${BL_PROP[$slot]}; return; fi
  bl_make_object "$BL_OBJECT_PROTO"; local p=$RET
  bl_prop_set_key "$p" constructor "$fn" >/dev/null
  bl_prop_set_key "$fn" prototype "$p" >/dev/null
  RET=$p
}
bl_builtin_ensure_prototype() { bl_expect_arity $# 1 ensure-prototype || return; bl_ensure_prototype "$1"; }
bl_builtin_new_object() {
  bl_expect_min_arity $# 1 new || return
  local fn=$1; shift
  case ${BL_TYPE[$fn]-} in builtin|closure|compiled|bound) ;; *) echo 'BLisp: new expects function' >&2; return 1;; esac
  bl_ensure_prototype "$fn" || return; local proto=$RET
  bl_make_object "$proto"; local obj=$RET
  bl_apply_this "$fn" "$obj" "$@" || return
  RET=$obj
}
bl_builtin_method_call() {
  bl_expect_min_arity $# 2 method-call || return
  local obj=$1 keyv=$2; shift 2; bl_prop_key "$keyv" || return; local k=$RET
  bl_prop_get_key "$obj" "$k"; local fn=$RET
  [[ $fn != nil ]] || { echo "BLisp: no method '$k'" >&2; return 1; }
  bl_apply_this "$fn" "$obj" "$@"
}
bl_collect_spread_parts() {
  BL_SPREAD_RESULT=(); local part v
  for part in "$@"; do
    bl_iter_values "$part" || return
    for v in "${BL_ITER_RESULT[@]}"; do BL_SPREAD_RESULT+=("$v"); done
  done
}
declare -ag BL_SPREAD_RESULT=()

bl_builtin_call_spread() {
  bl_expect_min_arity $# 1 call-spread || return
  local fn=$1; shift; bl_collect_spread_parts "$@" || return
  bl_apply "$fn" "${BL_SPREAD_RESULT[@]}"
}
bl_builtin_method_call_spread() {
  bl_expect_min_arity $# 2 method-call-spread || return
  local obj=$1 keyv=$2; shift 2; bl_prop_key "$keyv" || return; local k=$RET
  bl_prop_get_key "$obj" "$k"; local fn=$RET
  [[ $fn != nil ]] || { echo "BLisp: no method '$k'" >&2; return 1; }
  bl_collect_spread_parts "$@" || return; bl_apply_this "$fn" "$obj" "${BL_SPREAD_RESULT[@]}"
}
bl_builtin_new_spread() {
  bl_expect_min_arity $# 1 new-spread || return
  local fn=$1; shift; bl_collect_spread_parts "$@" || return
  bl_builtin_new_object "$fn" "${BL_SPREAD_RESULT[@]}"
}
bl_builtin_array_spread() {
  bl_collect_spread_parts "$@" || return; bl_make_array "${BL_SPREAD_RESULT[@]}"
}
bl_builtin_super_call_spread() {
  bl_expect_min_arity $# 2 super-call-spread || return
  local parent=$1 thisv=$2; shift 2; bl_collect_spread_parts "$@" || return
  bl_apply_this "$parent" "$thisv" "${BL_SPREAD_RESULT[@]}"
}
bl_builtin_super_method_spread() {
  bl_expect_min_arity $# 3 super-method-spread || return
  local parent=$1 thisv=$2 keyv=$3; shift 3
  bl_ensure_prototype "$parent" || return; local p=$RET; bl_prop_key "$keyv" || return; local k=$RET
  bl_prop_get_key "$p" "$k"; local fn=$RET
  [[ $fn != nil ]] || { echo "BLisp: no super method '$k'" >&2; return 1; }
  bl_collect_spread_parts "$@" || return; bl_apply_this "$fn" "$thisv" "${BL_SPREAD_RESULT[@]}"
}

bl_builtin_super_call() { bl_expect_min_arity $# 2 super || return; local parent=$1 thisv=$2; shift 2; bl_apply_this "$parent" "$thisv" "$@"; }
bl_builtin_super_method() {
  bl_expect_min_arity $# 3 super.method || return
  local parent=$1 thisv=$2 keyv=$3; shift 3
  bl_ensure_prototype "$parent" || return; local p=$RET; bl_prop_key "$keyv" || return; local k=$RET; bl_prop_get_key "$p" "$k"; local fn=$RET
  [[ $fn != nil ]] || { echo "BLisp: no super method '$k'" >&2; return 1; }
  bl_apply_this "$fn" "$thisv" "$@"
}
bl_builtin_instanceof() {
  bl_expect_arity $# 2 instanceof || return
  local obj=$1 fn=$2; bl_ensure_prototype "$fn" || { RET=false; return 0; }; local want=$RET cur=${BL_PROTO[$obj]-nil}
  while [[ $cur != nil ]]; do [[ $cur == "$want" ]] && { RET=true; return; }; cur=${BL_PROTO[$cur]-nil}; done
  RET=false
}

bl_builtin_values() {
  bl_expect_arity $# 1 values || return
  local obj=$1 i k; local count=${BL_KEY_COUNT[$1]-0}; local -a out=()
  for ((i=0;i<count;++i)); do k=${BL_KEY_AT["$obj|$i"]-}; [[ -n $k && -v 'BL_PROP["$obj|$k"]' ]] || continue; out+=("${BL_PROP["$obj|$k"]}"); done
  bl_make_array "${out[@]}"
}
bl_builtin_entries() {
  bl_expect_arity $# 1 entries || return
  local obj=$1 i k; local count=${BL_KEY_COUNT[$1]-0}; local -a out=()
  for ((i=0;i<count;++i)); do
    k=${BL_KEY_AT["$obj|$i"]-}; [[ -n $k && -v 'BL_PROP["$obj|$k"]' ]] || continue
    if [[ $k == $'\x1e'* ]]; then bl_make_string_from_hex "${k:1}"; else bl_make_string "$k"; fi; local kv=$RET; bl_make_array "$kv" "${BL_PROP["$obj|$k"]}"; out+=("$RET")
  done
  bl_make_array "${out[@]}"
}
bl_builtin_enumerate() {
  bl_expect_arity $# 1 enumerate || return; bl_iter_values "$1" || return
  local -a vals=("${BL_ITER_RESULT[@]}") out=(); local i
  for ((i=0;i<${#vals[@]};++i)); do bl_make_int "$i"; local iv=$RET; bl_make_array "$iv" "${vals[i]}"; out+=("$RET"); done
  bl_make_array "${out[@]}"
}
bl_builtin_zip() {
  bl_expect_min_arity $# 1 zip || return
  local -a seqs=("$@") lens=(); local s min=-1 i j
  # Materialize each iterable as a temporary BLisp array so iteration semantics stay uniform.
  local -a mats=()
  for s in "${seqs[@]}"; do bl_iter_values "$s" || return; bl_make_array "${BL_ITER_RESULT[@]}"; mats+=("$RET"); lens+=("${#BL_ITER_RESULT[@]}"); done
  for i in "${lens[@]}"; do ((min<0 || i<min)) && min=$i; done
  local -a out=() row=()
  for ((i=0;i<min;++i)); do
    row=(); for ((j=0;j<${#mats[@]};++j)); do bl_prop_get_key "${mats[j]}" "$i"; row+=("$RET"); done
    bl_make_array "${row[@]}"; out+=("$RET")
  done
  bl_make_array "${out[@]}"
}
bl_builtin_assert() {
  bl_expect_min_arity $# 1 assert || return
  bl_truthy "$1" && { RET=$1; return 0; }
  printf 'BLisp assertion failed' >&2
  if (($#>=2)); then printf ': ' >&2; bl_display "$2" >&2; fi
  printf '\n' >&2; return 1
}


# Binary-safe byte buffers. The storage representation never places a NUL in
# a Bash variable; binary I/O is encoded as octal escapes only at the final
# printf boundary.
bl_builtin_bytes() {
  if (($#==0)); then bl_make_bytes; return; fi
  if (($#==1)); then
    local v=$1 i n s ord
    case ${BL_TYPE[$v]-} in
      bytes) n=${BL_BYTES_LEN[$v]-0}; local -a copy=(); for ((i=0;i<n;++i)); do copy+=("${BL_BYTE_AT["$v|$i"]}"); done; bl_make_bytes "${copy[@]}"; return ;;
      string)
        bl_string_hex "$v" || return; local hex=$RET pair; local -a out=()
        for ((i=0;i<${#hex};i+=2)); do pair=${hex:i:2}; out+=("$((16#$pair))"); done
        bl_make_bytes "${out[@]}"; return ;;
      array|cons) bl_iter_values "$v" || return; bl_make_bytes_from_values "${BL_ITER_RESULT[@]}"; return ;;
    esac
  fi
  bl_make_bytes_from_values "$@"
}
bl_make_bytes_from_values() {
  local -a out=(); local v
  for v in "$@"; do bl_int_value "$v" || return; ((RET>=0 && RET<=255)) || { echo 'BLisp: bytes values must be 0..255' >&2; return 1; }; out+=("$RET"); done
  bl_make_bytes "${out[@]}"
}
bl_builtin_bytesp() { bl_expect_arity $# 1 bytes? || return; [[ ${BL_TYPE[$1]-} == bytes ]] && RET=true || RET=false; }
bl_builtin_bytes_hex() { local b=$1; shift; bl_expect_arity $# 0 bytes.hex || return; local i n=${BL_BYTES_LEN[$b]-0} out=; for ((i=0;i<n;++i)); do printf -v out '%s%02x' "$out" "${BL_BYTE_AT["$b|$i"]}"; done; bl_make_string "$out"; }
bl_builtin_bytes_slice() { local b=$1; shift; bl_expect_min_arity $# 1 bytes.slice || return; bl_int_value "$1" || return; local start=$RET; local n=${BL_BYTES_LEN[$b]-0}; local end=$n; if (($#>=2)); then bl_int_value "$2" || return; end=$RET; fi; ((start<0)) && start=$((n+start)); ((end<0)) && end=$((n+end)); ((start<0)) && start=0; ((end>n)) && end=$n; ((end<start)) && end=$start; local -a out=(); local i; for ((i=start;i<end;++i)); do out+=("${BL_BYTE_AT["$b|$i"]}"); done; bl_make_bytes "${out[@]}"; }
bl_builtin_bytes_to_string() {
  local b=$1; shift; bl_expect_max_arity $# 1 bytes.decode || return
  if (($#)); then
    bl_string_value "$1" || return; local enc=${RET,,}
    case $enc in utf-8|utf8) ;; *) bl_raise_error encoding "unsupported text encoding: $RET"; return ;; esac
  fi
  local i n=${BL_BYTES_LEN[$b]-0} x hx hex=
  for ((i=0;i<n;++i)); do x=${BL_BYTE_AT["$b|$i"]}; printf -v hx '%02x' "$x"; hex+=$hx; done
  bl_make_string_from_hex "$hex"
}
bl_builtin_str_encode() {
  local s=$1; shift; bl_expect_max_arity $# 1 string.encode || return
  if (($#)); then
    bl_string_value "$1" || return; local enc=${RET,,}
    case $enc in utf-8|utf8) ;; *) bl_raise_error encoding "unsupported text encoding: $RET"; return ;; esac
  fi
  bl_builtin_bytes "$s"
}
bl_builtin_bytes_push() { local b=$1; shift; local n=${BL_BYTES_LEN[$b]-0} v; for v in "$@"; do bl_int_value "$v" || return; ((RET>=0 && RET<=255)) || { echo 'BLisp: byte must be 0..255' >&2; return 1; }; BL_BYTE_AT["$b|$n"]=$RET; ((n++)) || true; done; BL_BYTES_LEN[$b]=$n; bl_make_int "$n"; }

bl_bytes_write_fd() {
  local b=$1 fd=$2 i x esc= chunk=0; local n=${BL_BYTES_LEN[$b]-0}
  for ((i=0;i<n;++i)); do x=${BL_BYTE_AT["$b|$i"]}; printf -v esc '%s\\%03o' "$esc" "$x"; ((++chunk)) || true; if ((chunk>=2048)); then printf '%b' "$esc" >&"$fd" || return; esc=; chunk=0; fi; done
  [[ -z $esc ]] || printf '%b' "$esc" >&"$fd"
}
bl_bytes_write_path() { local b=$1 path=$2; : > "$path" || return; local fd; exec {fd}>"$path" || return; bl_bytes_write_fd "$b" "$fd"; local st=$?; exec {fd}>&-; return $st; }
bl_bytes_read_path() {
  local path=$1 text x; [[ -r $path ]] || return 1
  text=$(od -An -v -t u1 -- "$path") || return
  local -a xs=(); for x in $text; do xs+=("$x"); done; bl_make_bytes "${xs[@]}"
}
bl_builtin_read_bytes() { bl_expect_arity $# 1 readBytes || return; bl_string_value "$1" || return; local path=$RET; bl_bytes_read_path "$path" || bl_raise_error io "cannot read bytes: $path"; }
bl_builtin_write_bytes() { bl_expect_arity $# 2 writeBytes || return; bl_string_value "$1" || return; local path=$RET; [[ ${BL_TYPE[$2]-} == bytes ]] || { echo 'BLisp: writeBytes expects bytes' >&2; return 1; }; bl_bytes_write_path "$2" "$path" || { bl_raise_error io "cannot write bytes: $path"; return; }; RET=nil; }

# Language hash primitive.
#
# Contract:
#   * a == b  =>  hash(a) == hash(b) for all hashable values;
#   * values whose structural equality can change through ordinary mutation are
#     not hashable (arrays and mutable bytes);
#   * immutable cons/list structure is structurally hashable;
#   * object-like values use stable identity hashing unless they opt into
#     semantic equality with __eq__; defining __eq__ without __hash__ makes the
#     value unhashable, matching the invariant rather than silently mixing
#     semantic equality with identity hashing.
#
# User-defined __hash__ is trusted to be stable and compatible with __eq__. A
# program that mutates state consulted by its own __hash__ violates that
# protocol contract, just as a mutable hash key would in other languages.
bl_hash_text() {
  local text=$1 h=1469598103934665603 i ord; local LC_ALL=C
  for ((i=0;i<${#text};++i)); do printf -v ord '%d' "'${text:i:1}"; (( h ^= ord, h *= 1099511628211 )) || true; done
  BL_HASH=$h
}
BL_HASH=0

bl_unhashable() {
  local why=$1
  bl_raise_error unhashable "$why"
}

bl_hash_value() {
  local v=$1 h i n fn eqfn hv
  case $v in nil) BL_HASH=0; return;; false) BL_HASH=1; return;; true) BL_HASH=2; return;; esac
  case ${BL_TYPE[$v]-} in
    int) BL_HASH=${BL_A[$v]} ;;
    float)
      # Equality-compatible numeric hashing: 4 and 4.0 hash alike because they
      # are equal in BLisp's numeric equality domain.
      local __norm
      __norm=$(awk -v x="${BL_A[$v]}" 'BEGIN{if(x==int(x)) printf "%.0f",x; else printf "%.17g",x}') || return
      if [[ $__norm =~ ^-?[0-9]+$ ]]; then BL_HASH=$__norm; else bl_hash_text "f:$__norm"; fi ;;
    string) bl_string_hex "$v" || return; bl_hash_text "s:$RET" ;;
    symbol) bl_hash_text "y:${BL_A[$v]}" ;;
    range) bl_hash_text "r:${BL_A[$v]}:${BL_B[$v]}:${BL_C[$v]-0}" ;;
    bytes)
      bl_unhashable 'mutable bytes values are not hashable'; return ;;
    array)
      bl_unhashable 'mutable arrays are not hashable'; return ;;
    cons)
      # Cons cells have no language mutation primitive, so list/pair structure
      # is immutable and may safely use structural hashing.
      h=314159265358979323; local cur=$v
      while [[ $cur != nil ]]; do
        if [[ ${BL_TYPE[$cur]-} != cons ]]; then
          bl_hash_value "$cur" || return; (( h ^= BL_HASH, h *= 1099511628211 )) || true; break
        fi
        bl_hash_value "${BL_A[$cur]}" || return; (( h ^= BL_HASH, h *= 1099511628211 )) || true
        cur=${BL_B[$cur]}
      done
      BL_HASH=$h ;;
    object|builtin|closure|compiled|bound)
      bl_prop_get_key "$v" __hash__; fn=$RET
      if [[ $fn != nil ]]; then
        bl_apply_this "$fn" "$v" || return
        bl_int_value "$RET" || { bl_raise_error unhashable '__hash__ must return an integer'; return; }
        BL_HASH=$RET
      else
        bl_prop_get_key "$v" __eq__; eqfn=$RET
        if [[ $eqfn != nil ]]; then
          bl_unhashable 'value defines __eq__ but not __hash__'; return
        fi
        # Heap IDs are monotonic identities in this runtime and therefore make
        # a stable identity hash for values using identity equality.
        [[ $v =~ ^v([0-9]+)$ ]] || { bl_unhashable 'value has no stable identity hash'; return; }
        BL_HASH=${BASH_REMATCH[1]}
      fi ;;
    *) bl_unhashable 'value is not hashable'; return ;;
  esac
}
bl_builtin_hash() { bl_expect_arity $# 1 hash || return; bl_hash_value "$1" || return; bl_make_int "$BL_HASH"; }

# POSIX ERE via Bash's regex engine. This is intentionally a small primitive:
# policy such as find-all, splitting, validation helpers, etc. lives in stdlib.
bl_builtin_regex_match() {
  bl_expect_arity $# 2 regexMatch || return
  bl_string_value "$1" || return; local pattern=$RET
  bl_string_value "$2" || return; local text=$RET status
  [[ $text =~ $pattern ]]; status=$?
  if ((status == 2)); then bl_raise_error regex "invalid regular expression: $pattern"; return; fi
  if ((status != 0)); then RET=nil; return 0; fi
  local full=${BASH_REMATCH[0]-} i
  local -a groups=()
  for ((i=1;i<${#BASH_REMATCH[@]};++i)); do bl_make_string "${BASH_REMATCH[$i]-}"; groups+=("$RET"); done
  bl_make_array "${groups[@]}"; local ga=$RET
  bl_make_object "$BL_OBJECT_PROTO"; local out=$RET
  bl_make_string "$full"; bl_prop_set_key "$out" full "$RET" >/dev/null
  bl_prop_set_key "$out" groups "$ga" >/dev/null
  RET=$out
}

# Exceptions are ordinary language values.  User code may throw any value;
# capability primitives use structured {kind, message, ...} error objects.
BL_THROWN=0
BL_THROW_VALUE=nil
bl_builtin_throw() { bl_expect_arity $# 1 throw || return; BL_THROWN=1; BL_THROW_VALUE=$1; RET=$1; return 1; }
bl_raise_error() {
  local kind=$1 message=$2
  bl_make_object "$BL_OBJECT_PROTO"; local err=$RET
  bl_make_symbol "$kind"; bl_prop_set_key "$err" kind "$RET" >/dev/null
  bl_make_string "$message"; bl_prop_set_key "$err" message "$RET" >/dev/null
  BL_THROWN=1; BL_THROW_VALUE=$err; RET=$err; return 1
}
bl_builtin_attempt() {
  bl_expect_min_arity $# 1 attempt || return
  local fn=$1; shift; local ok value
  BL_THROWN=0; BL_THROW_VALUE=nil
  if bl_apply "$fn" "$@"; then ok=true; value=$RET
  else
    if ((BL_THROWN)); then ok=false; value=$BL_THROW_VALUE; BL_THROWN=0; BL_THROW_VALUE=nil
    else return 1; fi
  fi
  bl_make_object "$BL_OBJECT_PROTO"; local out=$RET
  bl_prop_set_key "$out" ok "$ok" >/dev/null
  if [[ $ok == true ]]; then bl_prop_set_key "$out" value "$value" >/dev/null; else bl_prop_set_key "$out" error "$value" >/dev/null; fi
  RET=$out
}

# Environment and filesystem primitives intentionally expose capability-sized
# operations; path manipulation and policy belong in libraries.
#
# The language-visible process environment is deliberately isolated from Bash's
# variable namespace.  Exposing `printf -v "$user_name"` / `${!user_name}` here
# lets ordinary programs overwrite allocator/parser/runtime state.  Instead we
# snapshot the inherited *exported* environment once at runtime initialization
# and mutate this explicit map.  Child processes are launched with exactly this
# map (plus an optional per-call overlay), so interpreted and compiled programs
# have the same semantics without depending on Bash local/global scoping.
declare -Ag BL_PROCESS_ENV=()
declare -ag BL_PROCESS_ENV_ARGS=()

bl_env_name_valid() {
  # Unix environment entries are NAME=VALUE byte strings.  BLisp strings cannot
  # contain NUL already; disallow only the structural '=' and the empty name
  # rather than imposing Bash identifier syntax on the language.
  [[ -n $1 && $1 != *'='* ]]
}

bl_process_env_init() {
  BL_PROCESS_ENV=()
  local entry name value
  # Read the actual inherited process environment rather than Bash's exported
  # shell-variable namespace.  Environment names are not required to be valid
  # Bash identifiers, and exposing only `compgen -e` would accidentally make
  # the language model depend on what Bash chose to import as variables.
  while IFS= read -r -d '' entry; do
    [[ $entry == *=* ]] || continue
    name=${entry%%=*}; value=${entry#*=}
    bl_env_name_valid "$name" || continue
    BL_PROCESS_ENV["$name"]=$value
  done < <(command env -0)
}

bl_process_env_build_args() {
  local overlay=${1:-nil} k i count v
  local -A merged=()
  for k in "${!BL_PROCESS_ENV[@]}"; do merged["$k"]=${BL_PROCESS_ENV[$k]}; done
  if [[ $overlay != nil ]]; then
    [[ ${BL_TYPE[$overlay]-} == object ]] || { echo 'BLisp: process env must be object or nil' >&2; return 1; }
    count=${BL_KEY_COUNT[$overlay]-0}
    for ((i=0;i<count;++i)); do
      k=${BL_KEY_AT["$overlay|$i"]-}
      [[ -v 'BL_PROP["'$overlay'|'$k'"]' ]] || continue
      bl_env_name_valid "$k" || { printf 'BLisp: invalid environment variable name: %q\n' "$k" >&2; return 1; }
      v=${BL_PROP["$overlay|$k"]}
      if [[ $v == nil ]]; then
        unset 'merged[$k]'
      else
        bl_string_value "$v" || return
        merged["$k"]=$RET
      fi
    done
  fi
  BL_PROCESS_ENV_ARGS=()
  # Environment order has no semantic meaning.  Do not serialize keys through a
  # newline-delimited helper: Unix environment names may contain newlines even
  # though they cannot contain '=' or NUL.
  for k in "${!merged[@]}"; do BL_PROCESS_ENV_ARGS+=("$k=${merged[$k]}"); done
}

bl_builtin_env_get() {
  bl_expect_min_arity $# 1 env.get || return
  bl_string_value "$1" || return; local k=$RET
  bl_env_name_valid "$k" || { bl_raise_error value "invalid environment variable name"; return; }
  if [[ -v 'BL_PROCESS_ENV[$k]' ]]; then bl_make_string "${BL_PROCESS_ENV[$k]}"
  elif (($#>=2)); then RET=$2
  else RET=nil
  fi
}
bl_builtin_env_has() {
  bl_expect_arity $# 1 env.has || return
  bl_string_value "$1" || return; local k=$RET
  bl_env_name_valid "$k" || { bl_raise_error value "invalid environment variable name"; return; }
  [[ -v 'BL_PROCESS_ENV[$k]' ]] && RET=true || RET=false
}
bl_builtin_env_set() {
  bl_expect_arity $# 2 env.set || return
  bl_string_value "$1" || return; local k=$RET
  bl_env_name_valid "$k" || { bl_raise_error value "invalid environment variable name"; return; }
  bl_string_value "$2" || return; BL_PROCESS_ENV["$k"]=$RET; RET=$2
}
bl_builtin_env_unset() {
  bl_expect_arity $# 1 env.unset || return
  bl_string_value "$1" || return; local k=$RET
  bl_env_name_valid "$k" || { bl_raise_error value "invalid environment variable name"; return; }
  unset 'BL_PROCESS_ENV[$k]'; RET=nil
}

bl_builtin_fs_exists() { bl_expect_arity $# 1 fs.exists || return; bl_string_value "$1" || return; [[ -e $RET ]] && RET=true || RET=false; }
bl_builtin_fs_is_file() { bl_expect_arity $# 1 fs.isFile || return; bl_string_value "$1" || return; [[ -f $RET ]] && RET=true || RET=false; }
bl_builtin_fs_is_dir() { bl_expect_arity $# 1 fs.isDir || return; bl_string_value "$1" || return; [[ -d $RET ]] && RET=true || RET=false; }
bl_builtin_fs_cwd() { bl_expect_arity $# 0 fs.cwd || return; bl_make_string "$PWD"; }
bl_builtin_fs_chdir() { bl_expect_arity $# 1 fs.chdir || return; bl_string_value "$1" || return; local path=$RET; builtin cd -- "$path" 2>/dev/null || { bl_raise_error io "cannot chdir: $path"; return; }; bl_make_string "$PWD"; }
bl_builtin_fs_mkdir() { bl_expect_min_arity $# 1 fs.mkdir || return; bl_string_value "$1" || return; local path=$RET parents=false; (($#>=2)) && parents=$2; if bl_truthy "$parents"; then mkdir -p -- "$path" 2>/dev/null || { bl_raise_error io "cannot create directory: $path"; return; }; else mkdir -- "$path" 2>/dev/null || { bl_raise_error io "cannot create directory: $path"; return; }; fi; RET=nil; }
bl_builtin_fs_remove() { bl_expect_min_arity $# 1 fs.remove || return; bl_string_value "$1" || return; local path=$RET recursive=false; (($#>=2)) && recursive=$2; if [[ -d $path ]] && bl_truthy "$recursive"; then rm -rf -- "$path" 2>/dev/null || { bl_raise_error io "cannot remove: $path"; return; }; else rm -f -- "$path" 2>/dev/null || { bl_raise_error io "cannot remove: $path"; return; }; fi; RET=nil; }
bl_builtin_fs_rename() { bl_expect_arity $# 2 fs.rename || return; bl_string_value "$1" || return; local a=$RET; bl_string_value "$2" || return; local b=$RET; mv -- "$a" "$b" 2>/dev/null || { bl_raise_error io "cannot rename: $a -> $b"; return; }; RET=nil; }
bl_builtin_fs_size() { bl_expect_arity $# 1 fs.size || return; bl_string_value "$1" || return; local path=$RET n; [[ -f $path ]] || { bl_raise_error io "fs.size requires a readable file: $path"; return; }; n=$(wc -c < "$path") || return; n=${n//[[:space:]]/}; bl_make_int "$n"; }
bl_builtin_fs_list() {
  bl_expect_arity $# 1 fs.list || return; bl_string_value "$1" || return; local dir=$RET p base; [[ -d $dir ]] || { bl_raise_error io "not a directory: $dir"; return; }
  local -a out=(); while IFS= read -r -d '' p; do base=${p##*/}; bl_make_string "$base"; out+=("$RET"); done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
  bl_make_array "${out[@]}"
}

bl_option_get() {
  local opts=$1 key=$2 default=$3
  if [[ $opts == nil ]]; then RET=$default; return 0; fi
  [[ ${BL_TYPE[$opts]-} == object ]] || { echo 'BLisp: options must be object or nil' >&2; return 1; }
  bl_prop_get_key "$opts" "$key" || return
  [[ $RET == nil ]] && RET=$default
  # A present, non-nil option is success too.  The old one-liner leaked the
  # false status of the `[[ $RET == nil ]]` test and made every non-null option
  # abort its caller while leaving RET set to the option value.
  return 0
}
bl_builtin_process_run() {
  bl_expect_min_arity $# 1 process.run || return
  local av=$1 opts=${2:-nil}; bl_iter_values "$av" || return; local -a vals=("${BL_ITER_RESULT[@]}") cmd=(); local v
  ((${#vals[@]})) || { echo 'BLisp: process.run requires non-empty argv' >&2; return 1; }
  for v in "${vals[@]}"; do bl_string_value "$v" || return; cmd+=("$RET"); done
  local tmp; tmp=$(mktemp -d) || return; local in="$tmp/in" out="$tmp/out" err="$tmp/err" cwd= stdin=nil envobj=nil
  bl_option_get "$opts" cwd nil || { rm -rf "$tmp"; return; }; if [[ $RET != nil ]]; then bl_string_value "$RET" || { rm -rf "$tmp"; return; }; cwd=$RET; fi
  bl_option_get "$opts" stdin nil || { rm -rf "$tmp"; return; }; stdin=$RET
  bl_option_get "$opts" env nil || { rm -rf "$tmp"; return; }; envobj=$RET
  if [[ $stdin == nil ]]; then : > "$in"; elif [[ ${BL_TYPE[$stdin]-} == bytes ]]; then bl_bytes_write_path "$stdin" "$in" || { rm -rf "$tmp"; return; }; elif [[ ${BL_TYPE[$stdin]-} == string ]]; then bl_string_write_path "$stdin" "$in" || { rm -rf "$tmp"; return; }; else echo 'BLisp: process stdin must be string, bytes, or nil' >&2; rm -rf "$tmp"; return 1; fi
  bl_process_env_build_args "$envobj" || { rm -rf "$tmp"; return; }
  local -a envargs=("${BL_PROCESS_ENV_ARGS[@]}")
  local status
  if [[ -n $cwd ]]; then
    if ( builtin cd -- "$cwd" && command env -i "${envargs[@]}" "${cmd[@]}" ) < "$in" > "$out" 2> "$err"; then status=0; else status=$?; fi
  else
    if ( command env -i "${envargs[@]}" "${cmd[@]}" ) < "$in" > "$out" 2> "$err"; then status=0; else status=$?; fi
  fi
  bl_bytes_read_path "$out" || { rm -rf "$tmp"; return; }; local stdout=$RET
  bl_bytes_read_path "$err" || { rm -rf "$tmp"; return; }; local stderr=$RET
  rm -rf "$tmp"
  bl_make_object "$BL_OBJECT_PROTO"; local res=$RET; bl_make_int "$status"; bl_prop_set_key "$res" status "$RET" >/dev/null; bl_prop_set_key "$res" stdout "$stdout" >/dev/null; bl_prop_set_key "$res" stderr "$stderr" >/dev/null; RET=$res
}
bl_builtin_process_spawn() {
  bl_expect_min_arity $# 1 process.spawn || return
  local av=$1 opts=${2:-nil}; bl_iter_values "$av" || return; local -a vals=("${BL_ITER_RESULT[@]}") cmd=(); local v
  ((${#vals[@]})) || { echo 'BLisp: process.spawn requires non-empty argv' >&2; return 1; }
  for v in "${vals[@]}"; do bl_string_value "$v" || return; cmd+=("$RET"); done
  local tmp; tmp=$(mktemp -d) || return; local in="$tmp/in" out="$tmp/out" err="$tmp/err" statusf="$tmp/status" cwd= stdin=nil envobj=nil
  bl_option_get "$opts" cwd nil || { rm -rf "$tmp"; return; }; if [[ $RET != nil ]]; then bl_string_value "$RET" || { rm -rf "$tmp"; return; }; cwd=$RET; fi
  bl_option_get "$opts" stdin nil || { rm -rf "$tmp"; return; }; stdin=$RET
  bl_option_get "$opts" env nil || { rm -rf "$tmp"; return; }; envobj=$RET
  if [[ $stdin == nil ]]; then : > "$in"; elif [[ ${BL_TYPE[$stdin]-} == bytes ]]; then bl_bytes_write_path "$stdin" "$in" || { rm -rf "$tmp"; return; }; elif [[ ${BL_TYPE[$stdin]-} == string ]]; then bl_string_write_path "$stdin" "$in" || { rm -rf "$tmp"; return; }; else echo 'BLisp: process stdin must be string, bytes, or nil' >&2; rm -rf "$tmp"; return 1; fi
  bl_process_env_build_args "$envobj" || { rm -rf "$tmp"; return; }
  local -a envargs=("${BL_PROCESS_ENV_ARGS[@]}")
  (
    set +e
    if [[ -n $cwd ]]; then builtin cd -- "$cwd" || { printf '%d\n' 125 > "$statusf"; exit 0; }; fi
    command env -i "${envargs[@]}" "${cmd[@]}"
    local_rc=$?
    printf '%d\n' "$local_rc" > "$statusf"
    exit 0
  ) < "$in" > "$out" 2> "$err" &
  local pid=$!
  bl_make_object "$BL_PROCESS_HANDLE_PROTO"; local obj=$RET
  bl_make_int "$pid"; bl_prop_set_key "$obj" pid "$RET" >/dev/null
  bl_make_string "$tmp"; bl_prop_set_key "$obj" _dir "$RET" >/dev/null
  bl_prop_set_key "$obj" closed false >/dev/null
  RET=$obj
}
bl_process_handle_info() {
  local obj=$1
  bl_prop_get_key "$obj" closed; bl_truthy "$RET" && { echo 'BLisp: process handle is closed' >&2; return 1; }
  bl_prop_get_key "$obj" pid; [[ ${BL_TYPE[$RET]-} == int ]] || { echo 'BLisp: invalid process handle' >&2; return 1; }; BL_PROC_PID=${BL_A[$RET]}
  bl_prop_get_key "$obj" _dir; [[ ${BL_TYPE[$RET]-} == string ]] || { echo 'BLisp: invalid process handle' >&2; return 1; }; BL_PROC_DIR=${BL_A[$RET]}
}
BL_PROC_PID= BL_PROC_DIR=
bl_process_status_value() {
  local dir=$1 statusf="$1/status" st
  [[ -f $statusf ]] || { RET=nil; return 0; }
  IFS= read -r st < "$statusf" || return
  [[ $st =~ ^[0-9]+$ ]] || { echo 'BLisp: corrupt process status' >&2; return 1; }
  bl_make_int "$st"
}
bl_builtin_process_handle_poll() {
  local obj=$1; shift; bl_expect_arity $# 0 process.poll || return; bl_process_handle_info "$obj" || return
  bl_process_status_value "$BL_PROC_DIR"
}
bl_builtin_process_handle_wait() {
  local obj=$1; shift; bl_expect_arity $# 0 process.wait || return; bl_process_handle_info "$obj" || return
  local pid=$BL_PROC_PID dir=$BL_PROC_DIR
  while [[ ! -f $dir/status ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null || true; [[ -f $dir/status ]] || { echo 'BLisp: child exited without status' >&2; return 1; }; break; fi
    sleep 0.01
  done
  wait "$pid" 2>/dev/null || true
  bl_process_status_value "$dir"
}
bl_builtin_process_handle_kill() {
  local obj=$1; shift; bl_expect_min_arity $# 0 process.kill || return; bl_process_handle_info "$obj" || return
  local sig=TERM
  if (($#)); then
    case ${BL_TYPE[$1]-} in int) sig=${BL_A[$1]} ;; string|symbol) sig=${BL_A[$1]} ;; *) echo 'BLisp: process.kill signal must be int/string/symbol' >&2; return 1;; esac
  fi
  [[ $sig =~ ^[A-Za-z0-9]+$ ]] || { echo 'BLisp: invalid signal' >&2; return 1; }
  kill -s "$sig" "$BL_PROC_PID" 2>/dev/null || { bl_process_status_value "$BL_PROC_DIR"; [[ $RET != nil ]] && { RET=false; return 0; }; echo 'BLisp: kill failed' >&2; return 1; }
  RET=true
}
bl_builtin_process_handle_output() {
  local which=$1 obj=$2; shift 2; bl_expect_arity $# 0 "process.$which" || return; bl_process_handle_info "$obj" || return
  bl_bytes_read_path "$BL_PROC_DIR/$which"
}
bl_builtin_process_handle_stdout() { local obj=$1; shift; bl_builtin_process_handle_output out "$obj" "$@"; }
bl_builtin_process_handle_stderr() { local obj=$1; shift; bl_builtin_process_handle_output err "$obj" "$@"; }
bl_builtin_process_handle_result() {
  local obj=$1; shift; bl_expect_arity $# 0 process.result || return
  bl_builtin_process_handle_wait "$obj" || return; local status=$RET
  bl_process_handle_info "$obj" || return; local dir=$BL_PROC_DIR
  bl_bytes_read_path "$dir/out" || return; local stdout=$RET
  bl_bytes_read_path "$dir/err" || return; local stderr=$RET
  bl_make_object "$BL_OBJECT_PROTO"; local res=$RET; bl_prop_set_key "$res" status "$status" >/dev/null; bl_prop_set_key "$res" stdout "$stdout" >/dev/null; bl_prop_set_key "$res" stderr "$stderr" >/dev/null; RET=$res
}
bl_builtin_process_handle_close() {
  local obj=$1; shift; bl_expect_arity $# 0 process.close || return; bl_process_handle_info "$obj" || return
  bl_process_status_value "$BL_PROC_DIR" || return; [[ $RET != nil ]] || { echo 'BLisp: cannot close a running process handle' >&2; return 1; }
  wait "$BL_PROC_PID" 2>/dev/null || true
  rm -rf -- "$BL_PROC_DIR" || return; bl_prop_set_key "$obj" closed true >/dev/null; RET=nil
}

bl_builtin_process_which() {
  bl_expect_arity $# 1 process.which || return; bl_string_value "$1" || return
  local name=$RET path dir candidate
  if [[ $name == */* ]]; then
    [[ -f $name && -x $name ]] || { RET=nil; return 0; }
    bl_make_string "$name"; return
  fi
  path=${BL_PROCESS_ENV[PATH]-}
  local oldifs=$IFS; IFS=:
  for dir in $path; do
    [[ -n $dir ]] || dir=.
    candidate=$dir/$name
    if [[ -f $candidate && -x $candidate ]]; then IFS=$oldifs; bl_make_string "$candidate"; return; fi
  done
  IFS=$oldifs; RET=nil
}
bl_builtin_exit() { bl_expect_min_arity $# 0 exit || return; local code=0; if (($#)); then bl_int_value "$1" || return; code=$RET; fi; exit "$code"; }

bl_builtin_random_bytes() { bl_expect_arity $# 1 randomBytes || return; bl_int_value "$1" || return; local n=$RET; ((n>=0)) || { echo 'BLisp: randomBytes length must be >= 0' >&2; return 1; }; local text x; text=$(od -An -N "$n" -v -t u1 /dev/urandom) || return; local -a xs=(); for x in $text; do xs+=("$x"); done; bl_make_bytes "${xs[@]}"; }
bl_builtin_sleep_ms() { bl_expect_arity $# 1 sleepMs || return; bl_int_value "$1" || return; local ms=$RET; ((ms>=0)) || { echo 'BLisp: sleepMs requires nonnegative duration' >&2; return 1; }; local secs; printf -v secs '%d.%03d' "$((ms/1000))" "$((ms%1000))"; sleep "$secs" || return; RET=nil; }

# Streaming file handles share the same fd-based read/write machinery as TCP
# streams. Higher-level buffering, CSV, codecs, etc. can be library code.
bl_builtin_fs_open() {
  bl_expect_min_arity $# 1 fs.open || return; bl_string_value "$1" || return; local path=$RET mode=r fd
  if (($#>=2)); then bl_string_value "$2" || return; mode=$RET; fi
  case $mode in
    r) { exec {fd}<"$path"; } 2>/dev/null || { bl_raise_error io "cannot open for reading: $path"; return; } ;;
    w) { exec {fd}>"$path"; } 2>/dev/null || { bl_raise_error io "cannot open for writing: $path"; return; } ;;
    a) { exec {fd}>>"$path"; } 2>/dev/null || { bl_raise_error io "cannot open for append: $path"; return; } ;;
    *) echo 'BLisp: fs.open mode must be r, w, or a' >&2; return 1 ;;
  esac
  bl_make_object "$BL_FILE_PROTO"; local obj=$RET; bl_make_int "$fd"; bl_prop_set_key "$obj" fd "$RET" >/dev/null; bl_prop_set_key "$obj" closed false >/dev/null; bl_make_string "$mode"; bl_prop_set_key "$obj" mode "$RET" >/dev/null; bl_make_string "$path"; bl_prop_set_key "$obj" path "$RET" >/dev/null; RET=$obj
}

# Raw TCP client streams. This is intentionally below HTTP/WebSocket/etc.; those
# protocols can live in language libraries. It uses Bash's /dev/tcp facility.
bl_tcp_fd() { local obj=$1; bl_prop_get_key "$obj" fd; [[ ${BL_TYPE[$RET]-} == int ]] || { echo 'BLisp: invalid TCP stream' >&2; return 1; }; BL_TCP_FD=${BL_A[$RET]}; bl_prop_get_key "$obj" closed; if bl_truthy "$RET"; then echo 'BLisp: TCP stream is closed' >&2; return 1; fi; return 0; }
BL_TCP_FD=
bl_builtin_tcp_connect() {
  bl_expect_arity $# 2 net.connect || return; bl_string_value "$1" || return; local host=$RET; bl_int_value "$2" || return; local port=$RET fd
  if ! { exec {fd}<>"/dev/tcp/$host/$port"; } 2>/dev/null; then bl_raise_error network "connect failed: $host:$port"; return; fi
  bl_make_object "$BL_TCP_PROTO"; local obj=$RET; bl_make_int "$fd"; bl_prop_set_key "$obj" fd "$RET" >/dev/null; bl_prop_set_key "$obj" closed false >/dev/null; RET=$obj
}
bl_builtin_tcp_write() {
  local obj=$1; shift; bl_expect_arity $# 1 tcp.write || return; bl_tcp_fd "$obj" || return; local fd=$BL_TCP_FD data=$1 n=0
  case ${BL_TYPE[$data]-} in
    string) bl_string_hex "$data" || return; local __sh=$RET; bl_string_write_fd "$data" "$fd" || return; n=$((${#__sh}/2)) ;;
    bytes) bl_bytes_write_fd "$data" "$fd" || return; n=${BL_BYTES_LEN[$data]-0} ;;
    *) echo 'BLisp: tcp.write expects string or bytes' >&2; return 1 ;;
  esac
  bl_make_int "$n"
}
bl_builtin_tcp_read_line() {
  local obj=$1; shift; bl_expect_arity $# 0 tcp.readLine || return; bl_tcp_fd "$obj" || return; local fd=$BL_TCP_FD line=
  if IFS= read -r -u "$fd" line; then :; elif [[ -z $line ]]; then RET=nil; return; fi
  [[ $line == *$'\r' ]] && line=${line%$'\r'}
  bl_make_string "$line"
}
bl_builtin_tcp_read() {
  local obj=$1; shift; bl_expect_arity $# 1 tcp.read || return; bl_tcp_fd "$obj" || return; local fd=$BL_TCP_FD; bl_int_value "$1" || return; local n=$RET text x
  ((n>=0)) || { echo 'BLisp: tcp.read count must be nonnegative' >&2; return 1; }
  text=$(dd bs=1 count="$n" <&"$fd" 2>/dev/null | od -An -v -t u1) || return
  local -a xs=(); for x in $text; do xs+=("$x"); done; bl_make_bytes "${xs[@]}"
}
bl_builtin_tcp_read_all() {
  local obj=$1; shift; bl_expect_arity $# 0 tcp.readAll || return; bl_tcp_fd "$obj" || return; local fd=$BL_TCP_FD text x
  text=$(cat <&"$fd" | od -An -v -t u1) || return
  local -a xs=(); for x in $text; do xs+=("$x"); done; bl_make_bytes "${xs[@]}"
}
bl_builtin_tcp_close() {
  local obj=$1; shift; bl_expect_arity $# 0 tcp.close || return; bl_prop_get_key "$obj" closed; bl_truthy "$RET" && { RET=nil; return; }
  bl_prop_get_key "$obj" fd; [[ ${BL_TYPE[$RET]-} == int ]] || { echo 'BLisp: invalid TCP stream' >&2; return 1; }; local fd=${BL_A[$RET]}
  eval "exec ${fd}>&-"; bl_prop_set_key "$obj" closed true >/dev/null; RET=nil
}

# Conservative mark/sweep GC. Bash has dynamically scoped locals, which lets us
# conservatively discover value/environment IDs currently held by the runtime
# or compiled code. False positives retain garbage; they do not free live data.
declare -Ag BL_GC_VMARK=() BL_GC_EMARK=()
bl_gc_mark_value() {
  local v=$1 k i n child env packed
  [[ $v =~ ^v[0-9]+$ && -v 'BL_TYPE[$v]' ]] || return 0
  [[ -v 'BL_GC_VMARK[$v]' ]] && return 0; BL_GC_VMARK[$v]=1
  [[ ${BL_PROTO[$v]-nil} != nil ]] && bl_gc_mark_value "${BL_PROTO[$v]}"
  n=${BL_KEY_COUNT[$v]-0}; for ((i=0;i<n;++i)); do k=${BL_KEY_AT["$v|$i"]-}; [[ -v 'BL_PROP["$v|$k"]' ]] && bl_gc_mark_value "${BL_PROP["$v|$k"]}"; done
  case ${BL_TYPE[$v]} in
    cons) bl_gc_mark_value "${BL_A[$v]}"; bl_gc_mark_value "${BL_B[$v]}" ;;
    closure) bl_gc_mark_env "${BL_B[$v]}"; packed=${BL_C[$v]}; bl_gc_scan_ids "$packed" ;;
    compiled) bl_gc_mark_env "${BL_B[$v]}" ;;
    bound) bl_gc_mark_value "${BL_A[$v]}"; bl_gc_mark_value "${BL_B[$v]}"; bl_gc_mark_value "${BL_C[$v]}" ;;
    iterator) bl_gc_mark_value "${BL_A[$v]}"; bl_gc_mark_value "${BL_B[$v]}" ;;
  esac
}
bl_gc_mark_env() {
  local e=$1 key
  [[ $e =~ ^e[0-9]+$ && -v 'BL_ENV_PARENT[$e]' ]] || return 0
  [[ -v 'BL_GC_EMARK[$e]' ]] && return 0; BL_GC_EMARK[$e]=1
  [[ -n ${BL_ENV_PARENT[$e]-} ]] && bl_gc_mark_env "${BL_ENV_PARENT[$e]}"
  for key in "${!BL_ENV_BIND[@]}"; do [[ $key == "$e|"* ]] && bl_gc_mark_value "${BL_ENV_BIND[$key]}"; done
}
bl_gc_scan_ids() {
  local text=$1 tok rest=$1
  while [[ $rest =~ (v[0-9]+|e[0-9]+) ]]; do tok=${BASH_REMATCH[1]}; [[ $tok == v* ]] && bl_gc_mark_value "$tok" || bl_gc_mark_env "$tok"; rest=${rest#*"$tok"}; done
}
bl_gc_roots() {
  BL_GC_VMARK=(); BL_GC_EMARK=(); bl_gc_mark_env "$BL_GLOBAL_ENV"
  local name decl x; local -a excluded=(BL_TYPE BL_A BL_B BL_C BL_PROP BL_PROTO BL_KEY_COUNT BL_KEY_AT BL_ARR_LEN BL_BYTES_LEN BL_BYTE_AT BL_STR_HEX BL_ENV_PARENT BL_ENV_BIND BL_ENV_CONST BL_GC_VMARK BL_GC_EMARK)
  local ex skip
  while IFS= read -r name; do
    skip=0; for ex in "${excluded[@]}"; do [[ $name == "$ex" ]] && { skip=1; break; }; done; ((skip)) && continue
    decl=$(declare -p "$name" 2>/dev/null) || continue
    if [[ $decl == 'declare -a'* || $decl == 'declare -A'* ]]; then
      local -n __gc_ref="$name"; for x in "${__gc_ref[@]}"; do bl_gc_scan_ids "$x"; done; unset -n __gc_ref
    else x=${!name-}; bl_gc_scan_ids "$x"; fi
  done < <(compgen -A variable)
}
BL_GC_FREED_V=0 BL_GC_FREED_E=0
bl_gc_collect() {
  BL_GC_RUNNING=1; bl_gc_roots
  local v e key freedv=0 freede=0
  for v in "${!BL_TYPE[@]}"; do
    [[ -v 'BL_GC_VMARK[$v]' ]] && continue
    unset 'BL_TYPE[$v]' 'BL_A[$v]' 'BL_B[$v]' 'BL_C[$v]' 'BL_PROTO[$v]' 'BL_KEY_COUNT[$v]' 'BL_ARR_LEN[$v]' 'BL_BYTES_LEN[$v]' 'BL_STR_HEX[$v]'
    for key in "${!BL_PROP[@]}"; do [[ $key == "$v|"* ]] && unset 'BL_PROP[$key]'; done
    for key in "${!BL_KEY_AT[@]}"; do [[ $key == "$v|"* ]] && unset 'BL_KEY_AT[$key]'; done
    for key in "${!BL_BYTE_AT[@]}"; do [[ $key == "$v|"* ]] && unset 'BL_BYTE_AT[$key]'; done
    ((++freedv)) || true
  done
  for e in "${!BL_ENV_PARENT[@]}"; do
    [[ -v 'BL_GC_EMARK[$e]' ]] && continue
    unset 'BL_ENV_PARENT[$e]'; for key in "${!BL_ENV_BIND[@]}"; do [[ $key == "$e|"* ]] && { unset 'BL_ENV_BIND[$key]' 'BL_ENV_CONST[$key]'; }; done; ((++freede)) || true
  done
  BL_GC_FREED_V=$freedv; BL_GC_FREED_E=$freede; BL_GC_LAST_SEQ=$BL_SEQ; BL_GC_RUNNING=0; return 0
}
bl_builtin_gc() {
  bl_expect_arity $# 0 gc || return; bl_gc_collect || return
  local freedv=$BL_GC_FREED_V freede=$BL_GC_FREED_E
  bl_make_object "$BL_OBJECT_PROTO"; local res=$RET; bl_make_int "$freedv"; bl_prop_set_key "$res" values "$RET" >/dev/null; bl_make_int "$freede"; bl_prop_set_key "$res" envs "$RET" >/dev/null; RET=$res
}
bl_builtin_heap_stats() { bl_expect_arity $# 0 heapStats || return; bl_make_object "$BL_OBJECT_PROTO"; local res=$RET; bl_make_int "${#BL_TYPE[@]}"; bl_prop_set_key "$res" values "$RET" >/dev/null; bl_make_int "${#BL_ENV_PARENT[@]}"; bl_prop_set_key "$res" envs "$RET" >/dev/null; RET=$res; }

# Function.prototype-like virtual methods.
bl_builtin_fn_call() { local fn=$1; shift; local thisv=nil; (($#)) && { thisv=$1; shift; }; bl_apply_this "$fn" "$thisv" "$@"; }
bl_builtin_fn_apply() { local fn=$1; shift; bl_expect_arity $# 2 Function.apply || return; local thisv=$1 args=$2; bl_iter_values "$args" || return; bl_apply_this "$fn" "$thisv" "${BL_ITER_RESULT[@]}"; }
bl_builtin_fn_bind() { local fn=$1; shift; bl_expect_min_arity $# 1 Function.bind || return; local thisv=$1; shift; bl_list_from_array "$@"; local packed=$RET; bl_make_bound "$fn" "$thisv" "$packed"; }

# Array prototype methods.  Method builtins receive the receiver as argument 1.
bl_builtin_arr_push() { local a=$1; shift; [[ ${BL_TYPE[$a]-} == array ]] || { echo 'BLisp: push receiver is not array' >&2; return 1; }; local n v; n=${BL_ARR_LEN[$a]-0}; for v in "$@"; do bl_prop_set_key "$a" "$n" "$v" >/dev/null; ((n++)) || true; done; bl_make_int "$n"; }
bl_builtin_arr_pop() { local a=$1; shift; bl_expect_arity $# 0 pop || return; local n; n=${BL_ARR_LEN[$a]-0}; ((n)) || { RET=nil; return; }; ((n--)) || true; bl_prop_get_key "$a" "$n"; local v=$RET; unset 'BL_PROP["$a|$n"]'; BL_ARR_LEN[$a]=$n; RET=$v; }
bl_builtin_arr_join() { local a=$1; shift; [[ ${BL_TYPE[$a]-} == array ]] || return 1; local sepv; if (($#)); then sepv=$1; [[ ${BL_TYPE[$sepv]-} == string ]] || { echo 'BLisp: join separator must be string' >&2; return 1; }; else bl_make_string ','; sepv=$RET; fi; bl_string_hex "$sepv" || return; local seph=$RET out= i n; n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do ((i)) && out+=$seph; bl_prop_get_key "$a" "$i"; bl_value_to_string "$RET" || return; bl_string_hex "$RET" || return; out+=$RET; done; bl_make_string_from_hex "$out"; }
bl_builtin_arr_map() { local a=$1; shift; bl_expect_arity $# 1 map || return; local fn=$1 i n; n=${BL_ARR_LEN[$a]-0}; local -a out=(); for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; local v=$RET; bl_apply "$fn" "$v" || return; out+=("$RET"); done; bl_make_array "${out[@]}"; }
bl_builtin_arr_filter() { local a=$1; shift; bl_expect_arity $# 1 filter || return; local fn=$1 i n; n=${BL_ARR_LEN[$a]-0}; local -a out=(); for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; local v=$RET; bl_apply "$fn" "$v" || return; bl_truthy "$RET" && out+=("$v"); done; bl_make_array "${out[@]}"; }
bl_builtin_arr_reduce() { local a=$1; shift; bl_expect_arity $# 2 reduce || return; local fn=$1 acc=$2 i n; n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; local v=$RET; bl_apply "$fn" "$acc" "$v" || return; acc=$RET; done; RET=$acc; }
bl_builtin_arr_includes() { local a=$1; shift; bl_expect_arity $# 1 includes || return; local want=$1 i n; n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; bl_equal_value "$RET" "$want"; [[ $RET == true ]] && return; done; RET=false; }
bl_builtin_arr_slice() { local a=$1; shift; bl_expect_min_arity $# 1 slice || return; bl_int_value "$1" || return; local start=$RET n end; n=${BL_ARR_LEN[$a]-0}; end=$n; if (($#>=2)); then bl_int_value "$2" || return; end=$RET; fi; ((start<0)) && start=$((n+start)); ((end<0)) && end=$((n+end)); ((start<0)) && start=0; ((end>n)) && end=$n; local -a out=(); local i; for ((i=start;i<end;++i)); do bl_prop_get_key "$a" "$i"; out+=("$RET"); done; bl_make_array "${out[@]}"; }
bl_builtin_arr_each() { local a=$1; shift; bl_expect_arity $# 1 each || return; local fn=$1 i n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; bl_apply "$fn" "$RET" || return; done; RET=nil; }
bl_builtin_arr_any() { local a=$1; shift; bl_expect_arity $# 1 any || return; local fn=$1 i n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; bl_apply "$fn" "$RET" || return; bl_truthy "$RET" && { RET=true; return; }; done; RET=false; }
bl_builtin_arr_all() { local a=$1; shift; bl_expect_arity $# 1 all || return; local fn=$1 i n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; bl_apply "$fn" "$RET" || return; bl_truthy "$RET" || { RET=false; return; }; done; RET=true; }
bl_builtin_arr_find() { local a=$1; shift; bl_expect_arity $# 1 find || return; local fn=$1 i n=${BL_ARR_LEN[$a]-0} v; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; v=$RET; bl_apply "$fn" "$v" || return; bl_truthy "$RET" && { RET=$v; return; }; done; RET=nil; }
bl_builtin_arr_index_of() { local a=$1; shift; bl_expect_arity $# 1 indexOf || return; local want=$1 i n=${BL_ARR_LEN[$a]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; bl_equal_value "$RET" "$want"; if [[ $RET == true ]]; then bl_make_int "$i"; return; fi; done; bl_make_int -1; }
bl_builtin_arr_reversed() { local a=$1; shift; bl_expect_arity $# 0 reversed || return; local i n=${BL_ARR_LEN[$a]-0}; local -a out=(); for ((i=n-1;i>=0;--i)); do bl_prop_get_key "$a" "$i"; out+=("$RET"); done; bl_make_array "${out[@]}"; }
bl_builtin_arr_concat() { local a=$1; shift; local -a out=(); local src i n; for src in "$a" "$@"; do bl_iter_values "$src" || return; out+=("${BL_ITER_RESULT[@]}"); done; bl_make_array "${out[@]}"; }
bl_builtin_arr_sorted() {
  local a=$1; shift; (($#<=1)) || { echo 'BLisp: sorted expects zero or one comparator' >&2; return 1; }
  local cmp=${1:-nil} n=${BL_ARR_LEN[$a]-0} i j; local -a out=()
  for ((i=0;i<n;++i)); do bl_prop_get_key "$a" "$i"; out+=("$RET"); done
  local key prev c
  for ((i=1;i<n;++i)); do
    key=${out[i]}; j=$((i-1))
    while ((j>=0)); do
      prev=${out[j]}
      if [[ $cmp == nil ]]; then bl_builtin_gt "$prev" "$key" || return; [[ $RET == true ]] && c=1 || c=0
      else bl_apply "$cmp" "$prev" "$key" || return; bl_int_value "$RET" || return; ((RET>0)) && c=1 || c=0; fi
      ((c)) || break
      out[j+1]=${out[j]}; ((j--)) || true
    done
    out[j+1]=$key
  done
  bl_make_array "${out[@]}"
}

# String.prototype-like methods. Core operations work on canonical UTF-8 so
# embedded U+0000 is no different from any other code point.
bl_builtin_str_includes() { local s=$1; shift; bl_expect_arity $# 1 includes || return; bl_string_index_of_values "$s" "$1" || return; (( ${BL_A[$RET]} >= 0 )) && RET=true || RET=false; }
bl_builtin_str_starts_with() { local s=$1; shift; bl_expect_arity $# 1 startsWith || return; bl_string_hex "$s" || return; local h=$RET; bl_string_hex "$1" || return; [[ $h == "$RET"* ]] && RET=true || RET=false; }
bl_builtin_str_ends_with() { local s=$1; shift; bl_expect_arity $# 1 endsWith || return; bl_string_hex "$s" || return; local h=$RET; bl_string_hex "$1" || return; [[ $h == *"$RET" ]] && RET=true || RET=false; }
bl_builtin_str_slice() { local s=$1; shift; bl_expect_min_arity $# 1 slice || return; bl_string_cp_count "$s" || return; local n=${BL_A[$RET]}; bl_int_value "$1" || return; local start=$RET end=$n; if (($#>=2)); then bl_int_value "$2" || return; end=$RET; fi; bl_string_slice_value "$s" "$start" "$end"; }
bl_builtin_str_split() { local s=$1; shift; bl_expect_arity $# 1 split || return; bl_string_hex "$s" || return; local h=$RET; bl_string_hex "$1" || return; local d=$RET; [[ -n $d ]] || { echo 'BLisp: split delimiter may not be empty' >&2; return 1; }; local -a out=(); local off b step found part; while :; do off=0; found=-1; while ((off<=${#h}-${#d})); do if [[ ${h:off:${#d}} == "$d" ]]; then found=$off; break; fi; ((off<${#h})) || break; b=$((16#${h:off:2})); if ((b<=0x7f)); then step=2; elif ((b<=0xdf)); then step=4; elif ((b<=0xef)); then step=6; else step=8; fi; ((off+=step)) || true; done; ((found>=0)) || break; part=${h:0:found}; bl_make_string_from_hex "$part"; out+=("$RET"); h=${h:found+${#d}}; done; bl_make_string_from_hex "$h"; out+=("$RET"); bl_make_array "${out[@]}"; }
bl_string_case_map() { local s=$1 mode=$2 rest part raw mapped out= idx; bl_string_hex "$s" || return; rest=$RET; while bl_hex_find_zero_byte "$rest"; do idx=$BL_HEX_ZERO_AT; part=${rest:0:idx}; rest=${rest:idx+2}; bl_utf8_hex_to_text "$part" || return; raw=$RET; if [[ $mode == upper ]]; then mapped=${raw^^}; else mapped=${raw,,}; fi; bl_text_to_utf8_hex "$mapped"; out+="$RET"00; done; bl_utf8_hex_to_text "$rest" || return; raw=$RET; if [[ $mode == upper ]]; then mapped=${raw^^}; else mapped=${raw,,}; fi; bl_text_to_utf8_hex "$mapped"; out+=$RET; bl_make_string_from_hex "$out"; }
bl_builtin_str_upper() { local s=$1; shift; bl_expect_arity $# 0 toUpperCase || return; bl_string_case_map "$s" upper; }
bl_builtin_str_lower() { local s=$1; shift; bl_expect_arity $# 0 toLowerCase || return; bl_string_case_map "$s" lower; }
bl_builtin_str_repeat() { local s=$1; shift; bl_expect_arity $# 1 repeat || return; bl_string_hex "$s" || return; local h=$RET; bl_int_value "$1" || return; local n=$RET out= i; ((n>=0)) || { echo 'BLisp: repeat count must be nonnegative' >&2; return 1; }; for ((i=0;i<n;++i)); do out+=$h; done; bl_make_string_from_hex "$out"; }
bl_builtin_str_char_at() { local s=$1; shift; bl_expect_arity $# 1 charAt || return; bl_int_value "$1" || return; bl_string_at_value "$s" "$RET"; }
bl_builtin_str_index_of() { local s=$1; shift; bl_expect_arity $# 1 string.indexOf || return; bl_string_index_of_values "$s" "$1"; }
bl_builtin_str_trim() { local s=$1; shift; bl_expect_arity $# 0 trim || return; bl_string_hex "$s" || return; local h=$RET start=0 end=${#RET} pair; while ((start<end)); do pair=${h:start:2}; case $pair in 09|0a|0b|0c|0d|20) ((start+=2)) || true;; *) break;; esac; done; while ((end>start)); do pair=${h:end-2:2}; case $pair in 09|0a|0b|0c|0d|20) ((end-=2)) || true;; *) break;; esac; done; bl_make_string_from_hex "${h:start:end-start}"; }
bl_builtin_str_lines() { local s=$1; shift; bl_expect_arity $# 0 lines || return; bl_make_string_from_hex 0a; local nl=$RET; bl_builtin_str_split "$s" "$nl"; }
bl_builtin_str_words() { local s=$1; shift; bl_expect_arity $# 0 words || return; bl_string_hex "$s" || return; local h=$RET token= pair i; local -a out=(); for ((i=0;i<${#h};i+=2)); do pair=${h:i:2}; case $pair in 09|0a|0b|0c|0d|20) if [[ -n $token ]]; then bl_make_string_from_hex "$token"; out+=("$RET"); token=; fi ;; *) token+=$pair ;; esac; done; if [[ -n $token ]]; then bl_make_string_from_hex "$token"; out+=("$RET"); fi; bl_make_array "${out[@]}"; }
bl_builtin_to_string() { bl_expect_arity $# 1 String || return; bl_value_to_string "$1"; }
bl_builtin_to_number() { bl_expect_arity $# 1 Number || return; case ${BL_TYPE[$1]-} in int|float) RET=$1; return;; esac; bl_string_value "$1" || return; if [[ $RET =~ ^[-+]?[0-9]+$ ]]; then bl_make_int "$RET"; elif [[ $RET =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then bl_make_float "$RET"; else echo 'BLisp: num() requires numeric text' >&2; return 1; fi; }
bl_builtin_to_int() { bl_expect_arity $# 1 int || return; case ${BL_TYPE[$1]-} in int) RET=$1;; float) local x; x=$(awk -v x="${BL_A[$1]}" 'BEGIN{printf "%d", x}'); bl_make_int "$x";; string) bl_string_value "$1" || return; [[ $RET =~ ^[-+]?[0-9]+$ ]] || { echo 'BLisp: int() requires integer text' >&2; return 1; }; bl_make_int "$RET";; *) echo 'BLisp: int() expects number/string' >&2; return 1;; esac; }
bl_builtin_to_float() { bl_expect_arity $# 1 float || return; case ${BL_TYPE[$1]-} in float) RET=$1;; int) bl_make_float "${BL_A[$1]}.0";; string) bl_string_value "$1" || return; [[ $RET =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]] || { echo 'BLisp: float() requires numeric text' >&2; return 1; }; bl_make_float "$RET";; *) echo 'BLisp: float() expects number/string' >&2; return 1;; esac; }
bl_builtin_to_boolean() { bl_expect_arity $# 1 Boolean || return; bl_truthy "$1" && RET=true || RET=false; }
bl_builtin_math_abs() { bl_expect_arity $# 1 math.abs || return; bl_number_value "$1" || return; local n=$RET; if [[ ${BL_TYPE[$1]} == int ]]; then ((n<0)) && n=$((-n)); bl_make_int "$n"; else local out; out=$(awk -v x="$n" 'BEGIN{if(x<0)x=-x; printf "%.17g",x}'); bl_make_float "$out"; fi; }
bl_builtin_math_min() { bl_expect_min_arity $# 1 math.min || return; local best=$1 v; shift; for v in "$@"; do bl_cmp_number '<' "$v" "$best" || return; [[ $RET == true ]] && best=$v; done; RET=$best; }
bl_builtin_math_max() { bl_expect_min_arity $# 1 math.max || return; local best=$1 v; shift; for v in "$@"; do bl_cmp_number '>' "$v" "$best" || return; [[ $RET == true ]] && best=$v; done; RET=$best; }


bl_make_float() { bl_alloc; BL_TYPE[$RET]=float; BL_A[$RET]=$1; }
bl_number_value() {
  local v=$1
  case ${BL_TYPE[$v]-} in int|float) RET=${BL_A[$v]};; *) echo 'BLisp: expected number' >&2; return 1;; esac
}
bl_numeric_pair() {
  bl_number_value "$1" || return; BL_NUM_A=$RET; BL_NUM_TA=${BL_TYPE[$1]}
  bl_number_value "$2" || return; BL_NUM_B=$RET; BL_NUM_TB=${BL_TYPE[$2]}
}
BL_NUM_A= BL_NUM_B= BL_NUM_TA= BL_NUM_TB=
bl_float_bin() { local op=$1 a=$2 b=$3 out; out=$(awk -v a="$a" -v b="$b" -v op="$op" 'BEGIN { if(op=="+") x=a+b; else if(op=="-") x=a-b; else if(op=="*") x=a*b; else if(op=="/") x=a/b; printf "%.17g", x }') || return; bl_make_float "$out"; }
bl_float_cmp() { local op=$1 a=$2 b=$3; if awk -v a="$a" -v b="$b" -v op="$op" 'BEGIN { ok=(op=="<"?a<b:op=="<="?a<=b:op==">"?a>b:op==">="?a>=b:a==b); exit !ok }'; then RET=true; else RET=false; fi; }

# Builtins.
bl_expect_arity() { local got=$1 want=$2 name=$3; (( got == want )) || { echo "BLisp: $name expects $want args, got $got" >&2; return 1; }; }
bl_expect_min_arity() { local got=$1 want=$2 name=$3; (( got >= want )) || { echo "BLisp: $name expects >=$want args, got $got" >&2; return 1; }; }
bl_expect_max_arity() { local got=$1 want=$2 name=$3; (( got <= want )) || { echo "BLisp: $name expects <=$want args, got $got" >&2; return 1; }; }

BL_PROTOCOL_FOUND=0
bl_try_binary_protocol() {
  local left=$1 method=$2 right=$3
  BL_PROTOCOL_FOUND=0
  [[ $left != nil && $left != true && $left != false && -n ${BL_TYPE[$left]-} ]] || return 1
  bl_prop_get_key "$left" "$method"; local fn=$RET; [[ $fn != nil ]] || return 1
  BL_PROTOCOL_FOUND=1
  bl_apply_this "$fn" "$left" "$right"
}
bl_try_protocol_pair() {
  local left=$1 forward=$2 right=$3 reverse=$4 st
  bl_try_binary_protocol "$left" "$forward" "$right"; st=$?
  ((BL_PROTOCOL_FOUND)) && return "$st"
  bl_try_binary_protocol "$right" "$reverse" "$left"; st=$?
  ((BL_PROTOCOL_FOUND)) && return "$st"
  return 2
}
bl_builtin_add() {
  (($#)) || { bl_make_int 0; return; }
  if (($#==2)); then
    bl_try_protocol_pair "$1" __add__ "$2" __radd__; local __pst=$?
    ((__pst != 2)) && return "$__pst"
  fi
  local first_type=${BL_TYPE[$1]-} v hasfloat=0
  case $first_type in
    int|float)
      local acc=${BL_A[$1]}; [[ $first_type == float ]] && hasfloat=1; shift
      for v in "$@"; do case ${BL_TYPE[$v]-} in int) ;; float) hasfloat=1;; *) echo 'BLisp: + does not coerce mixed types' >&2; return 1;; esac; if ((hasfloat)); then local aa=$acc; bl_float_bin + "$aa" "${BL_A[$v]}" || return; acc=${BL_A[$RET]}; else ((acc += BL_A[$v])) || true; fi; done
      ((hasfloat)) && bl_make_float "$acc" || bl_make_int "$acc" ;;
    string)
    local out=; for v in "$@"; do
      [[ ${BL_TYPE[$v]-} == string ]] || { echo 'BLisp: + does not coerce mixed types' >&2; return 1; }
      bl_string_hex "$v" || return
      out+=$RET
    done
    bl_make_string_from_hex "$out" ;;
    array)
      local -a out=(); local i n; for v in "$@"; do [[ ${BL_TYPE[$v]-} == array ]] || { echo 'BLisp: + does not coerce mixed types' >&2; return 1; }; n=${BL_ARR_LEN[$v]-0}; for ((i=0;i<n;++i)); do bl_prop_get_key "$v" "$i"; out+=("$RET"); done; done; bl_make_array "${out[@]}" ;;
    *) echo 'BLisp: + supports numbers, strings, arrays, or operator protocols' >&2; return 1 ;;
  esac
}
bl_builtin_sub() {
  bl_expect_min_arity $# 1 - || return
  if (($#==2)); then
    bl_try_protocol_pair "$1" __sub__ "$2" __rsub__; local __pst=$?
    ((__pst != 2)) && return "$__pst"
  fi
  bl_number_value "$1" || return; local acc=$RET typ=${BL_TYPE[$1]} v; shift
  if (($#==0)); then if [[ $typ == int ]]; then bl_make_int "$((-acc))"; else bl_float_bin - 0 "$acc"; fi; return; fi
  for v in "$@"; do bl_number_value "$v" || return; if [[ $typ == float || ${BL_TYPE[$v]} == float ]]; then bl_float_bin - "$acc" "$RET" || return; acc=${BL_A[$RET]}; typ=float; else ((acc-=RET)) || true; fi; done
  [[ $typ == float ]] && bl_make_float "$acc" || bl_make_int "$acc"
}
bl_builtin_mul() {
  if (($#==2)); then
    bl_try_protocol_pair "$1" __mul__ "$2" __rmul__; local __pst=$?
    ((__pst != 2)) && return "$__pst"
  fi
  local acc=1 typ=int v; for v in "$@"; do bl_number_value "$v" || return; if [[ $typ == float || ${BL_TYPE[$v]} == float ]]; then bl_float_bin '*' "$acc" "$RET" || return; acc=${BL_A[$RET]}; typ=float; else ((acc*=RET)) || true; fi; done; [[ $typ == float ]] && bl_make_float "$acc" || bl_make_int "$acc"
}
bl_builtin_div() {
  bl_expect_arity $# 2 / || return
  bl_try_protocol_pair "$1" __div__ "$2" __rdiv__; local __pst=$?
  ((__pst != 2)) && return "$__pst"
  bl_numeric_pair "$1" "$2" || return; awk -v b="$BL_NUM_B" 'BEGIN{exit !(b==0)}' && { echo 'BLisp: division by zero' >&2; return 1; }
  if [[ $BL_NUM_TA == int && $BL_NUM_TB == int ]]; then bl_make_int "$((BL_NUM_A/BL_NUM_B))"; else bl_float_bin / "$BL_NUM_A" "$BL_NUM_B"; fi
}
bl_builtin_mod() {
  bl_expect_arity $# 2 % || return
  bl_try_protocol_pair "$1" __mod__ "$2" __rmod__; local __pst=$?
  ((__pst != 2)) && return "$__pst"
  bl_int_value "$1" || return; local a=$RET; bl_int_value "$2" || return; ((RET!=0)) || { echo 'BLisp: modulo by zero' >&2; return 1; }; bl_make_int "$((a%RET))"
}
bl_builtin_bit_and() { bl_expect_arity $# 2 '&' || return; bl_int_value "$1" || return; local a=$RET; bl_int_value "$2" || return; bl_make_int "$((a & RET))"; }
bl_builtin_bit_or() { bl_expect_arity $# 2 '|' || return; bl_int_value "$1" || return; local a=$RET; bl_int_value "$2" || return; bl_make_int "$((a | RET))"; }
bl_builtin_bit_xor() { bl_expect_arity $# 2 '^' || return; bl_int_value "$1" || return; local a=$RET; bl_int_value "$2" || return; bl_make_int "$((a ^ RET))"; }
bl_builtin_bit_not() { bl_expect_arity $# 1 'bit-not' || return; bl_int_value "$1" || return; bl_make_int "$((~RET))"; }
bl_builtin_shl() { bl_expect_arity $# 2 '<<' || return; bl_int_value "$1" || return; local a=$RET; bl_int_value "$2" || return; local n=$RET; ((n>=0 && n<64)) || { echo 'BLisp: shift count must be in 0..63' >&2; return 1; }; bl_make_int "$((a << n))"; }
bl_builtin_shr() { bl_expect_arity $# 2 '>>' || return; bl_int_value "$1" || return; local a=$RET; bl_int_value "$2" || return; local n=$RET; ((n>=0 && n<64)) || { echo 'BLisp: shift count must be in 0..63' >&2; return 1; }; bl_make_int "$((a >> n))"; }
bl_builtin_pow() {
  bl_expect_arity $# 2 pow || return
  bl_try_protocol_pair "$1" __pow__ "$2" __rpow__; local __pst=$?
  ((__pst != 2)) && return "$__pst"
  if [[ ${BL_TYPE[$1]-} == int && ${BL_TYPE[$2]-} == int && ${BL_A[$2]} -ge 0 ]]; then bl_make_int "$(( ${BL_A[$1]} ** ${BL_A[$2]} ))"; return; fi
  bl_numeric_pair "$1" "$2" || return; local out; out=$(awk -v a="$BL_NUM_A" -v b="$BL_NUM_B" 'BEGIN{printf "%.17g", a^b}') || return; bl_make_float "$out"
}
bl_cmp_number() { local op=$1 a=$2 b=$3; bl_numeric_pair "$a" "$b" || return; if [[ $BL_NUM_TA == int && $BL_NUM_TB == int ]]; then case $op in '==') ((BL_NUM_A==BL_NUM_B));; '<') ((BL_NUM_A<BL_NUM_B));; '<=') ((BL_NUM_A<=BL_NUM_B));; '>') ((BL_NUM_A>BL_NUM_B));; '>=') ((BL_NUM_A>=BL_NUM_B));; esac && RET=true || RET=false; else bl_float_cmp "$op" "$BL_NUM_A" "$BL_NUM_B"; fi; }
bl_builtin_num_eq() { bl_cmp_number '==' "$1" "$2"; }
bl_compare_ordered() {
  local op=$1 a=$2 b=$3
  if [[ ${BL_TYPE[$a]-} == string && ${BL_TYPE[$b]-} == string ]]; then
    bl_string_hex "$a" || return; local av=$RET; bl_string_hex "$b" || return; local bv=$RET; local LC_ALL=C ok=0
    case $op in '<') [[ $av < $bv ]] && ok=1;; '<=') [[ $av < $bv || $av == "$bv" ]] && ok=1;; '>') [[ $av > $bv ]] && ok=1;; '>=') [[ $av > $bv || $av == "$bv" ]] && ok=1;; esac
    ((ok)) && RET=true || RET=false; return
  fi
  bl_cmp_number "$op" "$a" "$b"
}
bl_ordered_protocol() {
  local left=$1 forward=$2 right=$3 reverse=$4 fallback=$5 st
  bl_try_protocol_pair "$left" "$forward" "$right" "$reverse"; st=$?
  ((st != 2)) && return "$st"
  bl_compare_ordered "$fallback" "$left" "$right"
}
bl_builtin_lt() { bl_ordered_protocol "$1" __lt__ "$2" __gt__ '<'; }
bl_builtin_le() { bl_ordered_protocol "$1" __le__ "$2" __ge__ '<='; }
bl_builtin_gt() { bl_ordered_protocol "$1" __gt__ "$2" __lt__ '>'; }
bl_builtin_ge() { bl_ordered_protocol "$1" __ge__ "$2" __le__ '>='; }

bl_builtin_not() { bl_expect_arity $# 1 not || return; if bl_truthy "$1"; then RET=false; else RET=true; fi; }
bl_builtin_cons() { bl_expect_arity $# 2 cons || return; bl_cons "$1" "$2"; }
bl_builtin_car() { bl_expect_arity $# 1 car || return; [[ ${BL_TYPE[$1]-} == cons ]] || { echo 'BLisp: car expects pair' >&2; return 1; }; RET=${BL_A[$1]}; }
bl_builtin_cdr() { bl_expect_arity $# 1 cdr || return; [[ ${BL_TYPE[$1]-} == cons ]] || { echo 'BLisp: cdr expects pair' >&2; return 1; }; RET=${BL_B[$1]}; }
bl_builtin_list() { bl_list_from_array "$@"; }
bl_builtin_nullp() { bl_expect_arity $# 1 null? || return; [[ $1 == nil ]] && RET=true || RET=false; }
bl_builtin_pairp() { bl_expect_arity $# 1 pair? || return; [[ ${BL_TYPE[$1]-} == cons ]] && RET=true || RET=false; }
bl_builtin_numberp() { bl_expect_arity $# 1 number? || return; case ${BL_TYPE[$1]-} in int|float) RET=true;; *) RET=false;; esac; }
bl_builtin_stringp() { bl_expect_arity $# 1 string? || return; [[ ${BL_TYPE[$1]-} == string ]] && RET=true || RET=false; }
bl_builtin_symbolp() { bl_expect_arity $# 1 symbol? || return; [[ ${BL_TYPE[$1]-} == symbol ]] && RET=true || RET=false; }
bl_builtin_functionp() { bl_expect_arity $# 1 function? || return; case ${BL_TYPE[$1]-} in builtin|closure|compiled|bound) RET=true;; *) RET=false;; esac; }
bl_builtin_eqp() {
  bl_expect_arity $# 2 eq? || return
  if [[ $1 == "$2" ]]; then RET=true; return; fi
  local t1=${BL_TYPE[$1]-} t2=${BL_TYPE[$2]-}
  if [[ $t1 == string && $t2 == string ]]; then bl_string_hex "$1" || return; local __a=$RET; bl_string_hex "$2" || return; [[ $__a == "$RET" ]] && RET=true || RET=false; return; fi
  if [[ $t1 == "$t2" && ( $t1 == int || $t1 == float || $t1 == symbol ) && ${BL_A[$1]} == "${BL_A[$2]}" ]]; then RET=true; else RET=false; fi
}
# Structural equality is cycle-safe.  One top-level comparison owns a set of
# already-observed value pairs; revisiting a pair means that branch is already
# constrained by the same recursive equality relation.  This gives cyclic
# arrays the usual bisimulation semantics instead of recursing until the Bash
# stack explodes.  Custom __eq__ methods remain responsible for their own
# recursion if they call back into equality on custom object graphs.
bl_equal_value_inner() {
  local x=$1 y=$2
  if [[ $x == "$y" ]]; then RET=true; return; fi
  local tx=${BL_TYPE[$x]-} ty=${BL_TYPE[$y]-}
  # int and float are one numeric equality domain.  `===`/`is` remains the
  # identity/representation-sensitive operation when callers need that.
  if [[ ( $tx == int || $tx == float ) && ( $ty == int || $ty == float ) ]]; then
    bl_cmp_number '==' "$x" "$y"; return
  fi
  [[ $tx == "$ty" ]] || { RET=false; return; }
  case $tx in
    string) bl_string_hex "$x" || return; local __sx=$RET; bl_string_hex "$y" || return; [[ $__sx == "$RET" ]] && RET=true || RET=false ;;
    int|float|symbol) [[ ${BL_A[$x]} == "${BL_A[$y]}" ]] && RET=true || RET=false ;;
    range)
      [[ ${BL_A[$x]} == "${BL_A[$y]}" && ${BL_B[$x]} == "${BL_B[$y]}" && ${BL_C[$x]-0} == "${BL_C[$y]-0}" ]] && RET=true || RET=false ;;
    bytes)
      local __n=${BL_BYTES_LEN[$x]-0} __i
      [[ $__n == ${BL_BYTES_LEN[$y]-0} ]] || { RET=false; return; }
      for ((__i=0;__i<__n;++__i)); do
        [[ ${BL_BYTE_AT["$x|$__i"]} == ${BL_BYTE_AT["$y|$__i"]} ]] || { RET=false; return; }
      done
      RET=true ;;
    array)
      local __n=${BL_ARR_LEN[$x]-0} __i __pair="$x|$y"
      [[ $__n == ${BL_ARR_LEN[$y]-0} ]] || { RET=false; return; }
      [[ ${BL_EQUAL_SEEN[$__pair]-0} == 0 ]] || { RET=true; return; }
      BL_EQUAL_SEEN[$__pair]=1
      for ((__i=0;__i<__n;++__i)); do
        bl_prop_get_key "$x" "$__i"; local __a=$RET
        bl_prop_get_key "$y" "$__i"; local __b=$RET
        bl_equal_value_inner "$__a" "$__b" || return
        [[ $RET == true ]] || { RET=false; return 0; }
      done
      RET=true ;;
    object|builtin|closure|compiled|bound)
      bl_prop_get_key "$x" __eq__; local __eqfn=$RET
      if [[ $__eqfn != nil ]]; then bl_apply_this "$__eqfn" "$x" "$y" || return; else RET=false; fi ;;
    cons)
      local __pair="$x|$y"
      [[ ${BL_EQUAL_SEEN[$__pair]-0} == 0 ]] || { RET=true; return; }
      BL_EQUAL_SEEN[$__pair]=1
      bl_equal_value_inner "${BL_A[$x]}" "${BL_A[$y]}" || return
      [[ $RET == true ]] || { RET=false; return 0; }
      bl_equal_value_inner "${BL_B[$x]}" "${BL_B[$y]}"
      ;;
    *) RET=false ;;
  esac
}
bl_equal_value() {
  local -A BL_EQUAL_SEEN=()
  bl_equal_value_inner "$1" "$2"
}
bl_builtin_equalp() { bl_expect_arity $# 2 equal? || return; bl_equal_value "$1" "$2"; }

bl_builtin_print() { local v; for v in "$@"; do bl_display "$v"; done; RET=nil; }
bl_builtin_println() { local first=1 v; for v in "$@"; do ((first)) || printf ' '; bl_display "$v"; first=0; done; printf '\n'; RET=nil; }
bl_builtin_repr() { bl_expect_arity $# 1 repr || return; local s; s=$(bl_repr "$1"); bl_make_string "$s"; }
bl_builtin_string_append() { local out= v; for v in "$@"; do bl_string_hex "$v" || return; out+=$RET; done; bl_make_string_from_hex "$out"; }
bl_builtin_number_to_string() { bl_expect_arity $# 1 number-to-string || return; bl_number_value "$1" || return; bl_make_string "$RET"; }
bl_builtin_string_length() { bl_expect_arity $# 1 string-length || return; bl_string_cp_count "$1"; }
bl_builtin_string_eq() { bl_expect_arity $# 2 string=? || return; bl_string_hex "$1" || return; local a=$RET; bl_string_hex "$2" || return; [[ $a == "$RET" ]] && RET=true || RET=false; }

bl_builtin_string_to_number() {
  bl_expect_arity $# 1 string-to-number || return
  bl_string_value "$1" || return
  [[ $RET =~ ^-?[0-9]+$ ]] || { echo 'BLisp: string->number expects an integer string' >&2; return 1; }
  bl_make_int "$RET"
}
bl_builtin_substring() {
  bl_expect_arity $# 3 substring || return
  bl_int_value "$2" || return; local start=$RET
  bl_int_value "$3" || return; local end=$RET
  bl_string_cp_count "$1" || return; local n=${BL_A[$RET]}
  (( start >= 0 && end >= start && end <= n )) || { echo 'BLisp: substring bounds' >&2; return 1; }
  bl_string_slice_value "$1" "$start" "$end"
}
bl_builtin_string_split() {
  bl_expect_arity $# 2 string-split || return
  bl_string_hex "$1" || return; local s=$RET
  bl_string_hex "$2" || return; local d=$RET
  [[ -n $d ]] || { echo 'BLisp: string-split delimiter may not be empty' >&2; return 1; }
  local -a vals=(); local part
  while [[ $s == *"$d"* ]]; do
    part=${s%%"$d"*}; bl_make_string_from_hex "$part"; vals+=("$RET"); s=${s#*"$d"}
  done
  bl_make_string_from_hex "$s"; vals+=("$RET")
  bl_list_from_array "${vals[@]}"
}
bl_builtin_string_join() {
  bl_expect_arity $# 2 string-join || return
  local list=$1
  bl_string_hex "$2" || return; local d=$RET out= first=1 cur=$list
  while [[ $cur != nil ]]; do
    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp: string-join expects proper list' >&2; return 1; }
    bl_string_hex "${BL_A[$cur]}" || return
    if (( first )); then out=$RET; first=0; else out+="$d$RET"; fi
    cur=${BL_B[$cur]}
  done
  bl_make_string_from_hex "$out"
}
bl_builtin_string_contains() {
  bl_expect_arity $# 2 string-contains? || return
  bl_string_hex "$1" || return; local s=$RET
  bl_string_hex "$2" || return; local needle=$RET
  [[ $s == *"$needle"* ]] && RET=true || RET=false
}

bl_builtin_apply() { bl_expect_arity $# 2 apply || return; local fn=$1 list=$2; bl_list_to_array "$list" || return; bl_apply "$fn" "${BL_LIST_RESULT[@]}"; }
bl_builtin_error() { local v; printf 'BLisp error:' >&2; for v in "$@"; do printf ' ' >&2; bl_display "$v" >&2; done; printf '\n' >&2; return 1; }

bl_builtin_read_file() {
  bl_expect_arity $# 1 read-file || return
  bl_string_value "$1" || return; local path=$RET
  bl_bytes_read_path "$path" || { bl_raise_error io "cannot read text: $path"; return; }; local b=$RET
  bl_builtin_bytes_to_string "$b"
}
bl_builtin_write_file() { bl_expect_arity $# 2 write-file || return; bl_string_value "$1" || return; local path=$RET; [[ ${BL_TYPE[$2]-} == string ]] || { echo 'BLisp: write-file expects string data' >&2; return 1; }; bl_string_write_path "$2" "$path" || { bl_raise_error io "cannot write text: $path"; return; }; RET=nil; }
bl_builtin_argv() { local -a vs=(); local s; for s in "${BL_USER_ARGV[@]}"; do bl_make_string "$s"; vs+=("$RET"); done; bl_list_from_array "${vs[@]}"; }
bl_builtin_args() { local -a vs=(); local s; for s in "${BL_USER_ARGV[@]}"; do bl_make_string "$s"; vs+=("$RET"); done; bl_make_array "${vs[@]}"; }
declare -ag BL_USER_ARGV=()

# clock-ms: coarse but portable enough for demos; date is external.
bl_builtin_clock_ms() { local n; n=$(date +%s%3N 2>/dev/null || date +%s000); bl_make_int "$n"; }
bl_builtin_monotonic_ms() { local n; if [[ -r /proc/uptime ]]; then n=$(awk '{printf \"%.0f\", $1*1000}' /proc/uptime) || return; bl_make_int \"$n\"; else bl_raise_error unsupported 'monotonic clock is unavailable on this host'; fi; }

bl_install_builtins() {
  bl_env_new ''; BL_GLOBAL_ENV=$RET
  local spec name impl
  local -a specs=(
    '+:add' '-:sub' '*:mul' '/:div' '%:mod' '&:bit_and' '|:bit_or' '^:bit_xor' 'bit-not:bit_not' 'bitNot:bit_not' '<<:shl' '>>:shr' 'pow:pow' '@pow:pow' '=:num_eq' '<:lt' '<=:le' '>:gt' '>=:ge' 'j+:js_add'
    'not:not' 'cons:cons' 'car:car' 'cdr:cdr' 'list:list' 'null?:nullp' 'pair?:pairp'
    'number?:numberp' 'bytes?:bytesp' 'string?:stringp' 'symbol?:symbolp' 'function?:functionp' 'eq?:eqp' 'equal?:equalp'
    'print:print' 'println:println' 'repr:repr' 'string-append:string_append'
    'number->string:number_to_string' 'string->number:string_to_number' 'string-length:string_length' 'string=?:string_eq'
    'substring:substring' 'string-split:string_split' 'string-join:string_join' 'string-contains?:string_contains'
    'apply:apply' 'error:error' 'throw:throw' 'attempt:attempt' 'read-file:read_file' 'readBytes:read_bytes' 'writeBytes:write_bytes' 'bytes:bytes' 'randomBytes:random_bytes' 'sleepMs:sleep_ms' 'gc:gc' 'heapStats:heap_stats' 'exit:exit'  'write-file:write_file' 'argv:argv' 'clock-ms:clock_ms'
    'readFile:read_file' 'writeFile:write_file' 'clockMs:clock_ms' 'monotonicMs:monotonic_ms' 'args:args' 'regexMatch:regex_match' 'range-inclusive:range_inclusive' 'range-exclusive:range_exclusive' 'len:len' 'type:type_name' 'values:values' 'entries:entries' 'enumerate:enumerate' 'hash:hash' 'zip:zip' 'assert:assert'
    'object:object' 'array:array' 'object-merge:object_merge' 'toArray:to_array' 'toList:to_list' 'iterator:iterator' 'nextItem:next_item' 'get:get' '@get:get' 'set-prop!:set_prop' 'delete-prop!:delete_prop'
    'has-prop?:has_prop' 'own-prop?:own_prop' 'get-proto:get_proto' 'set-proto!:set_proto' 'keys:keys'
    'ensure-prototype:ensure_prototype' 'new-object:new_object' '@method-call:method_call'
    'call-spread:call_spread' '@method-call-spread:method_call_spread' 'new-spread:new_spread' 'array-spread:array_spread'
    '@super-call-spread:super_call_spread' '@super-method-spread:super_method_spread'
    '@super-call:super_call' '@super-method:super_method' 'instanceof:instanceof' 'typeof:typeof'
  )
  for spec in "${specs[@]}"; do name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl"; bl_env_define "$BL_GLOBAL_ENV" "$name" "$RET"; done

  bl_env_lookup "$BL_GLOBAL_ENV" error; bl_env_define "$BL_GLOBAL_ENV" panic "$RET" >/dev/null

  # Bootstrap prototype roots.
  bl_make_object nil; BL_OBJECT_PROTO=$RET
  bl_make_object "$BL_OBJECT_PROTO"; BL_ARRAY_PROTO=$RET
  bl_make_object "$BL_OBJECT_PROTO"; BL_FUNCTION_PROTO=$RET
  bl_make_object "$BL_OBJECT_PROTO"; BL_STRING_PROTO=$RET
  bl_make_object "$BL_OBJECT_PROTO"; BL_BYTES_PROTO=$RET

  # Callables created during bootstrap predate Function.prototype.  Repair the
  # invariant over the heap once; all subsequent callable construction goes
  # through bl_init_callable and cannot omit it.
  local k v
  for v in "${!BL_TYPE[@]}"; do
    case ${BL_TYPE[$v]-} in builtin|closure|compiled|bound) BL_PROTO[$v]=$BL_FUNCTION_PROTO;; esac
  done

  bl_make_builtin fn_call method; bl_prop_set_key "$BL_FUNCTION_PROTO" call "$RET" >/dev/null
  bl_make_builtin fn_apply method; bl_prop_set_key "$BL_FUNCTION_PROTO" apply "$RET" >/dev/null
  bl_make_builtin fn_bind method; bl_prop_set_key "$BL_FUNCTION_PROTO" bind "$RET" >/dev/null

  # Object.prototype
  bl_make_builtin has_own_method method; bl_prop_set_key "$BL_OBJECT_PROTO" hasOwnProperty "$RET" >/dev/null

  # Array.prototype
  local m
  for spec in 'push:arr_push' 'pop:arr_pop' 'join:arr_join' 'map:arr_map' 'filter:arr_filter' 'reduce:arr_reduce' 'fold:arr_reduce' 'includes:arr_includes' 'slice:arr_slice' 'each:arr_each' 'forEach:arr_each' 'any:arr_any' 'some:arr_any' 'all:arr_all' 'every:arr_all' 'find:arr_find' 'indexOf:arr_index_of' 'reversed:arr_reversed' 'concat:arr_concat' 'sorted:arr_sorted'; do
    name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl" method; bl_prop_set_key "$BL_ARRAY_PROTO" "$name" "$RET" >/dev/null
  done

  # String.prototype
  for spec in 'includes:str_includes' 'contains:str_includes' 'startsWith:str_starts_with' 'endsWith:str_ends_with' 'slice:str_slice' 'split:str_split' 'toUpperCase:str_upper' 'upper:str_upper' 'toLowerCase:str_lower' 'lower:str_lower' 'repeat:str_repeat' 'charAt:str_char_at' 'indexOf:str_index_of' 'trim:str_trim' 'encode:str_encode' 'lines:str_lines' 'words:str_words'; do
    name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl" method; bl_prop_set_key "$BL_STRING_PROTO" "$name" "$RET" >/dev/null
  done

  # Bytes.prototype
  for spec in 'hex:bytes_hex' 'slice:bytes_slice' 'toString:bytes_to_string' 'decode:bytes_to_string' 'push:bytes_push'; do
    name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl" method; bl_prop_set_key "$BL_BYTES_PROTO" "$name" "$RET" >/dev/null
  done

  # Callable conversion helpers, with a JS-shaped String.prototype.
  bl_make_builtin to_string; local StringFn=$RET; bl_prop_set_key "$StringFn" prototype "$BL_STRING_PROTO" >/dev/null; bl_env_define "$BL_GLOBAL_ENV" String "$StringFn" >/dev/null; bl_env_define "$BL_GLOBAL_ENV" str "$StringFn" >/dev/null
  bl_make_builtin to_number; local NumberFn=$RET; bl_env_define "$BL_GLOBAL_ENV" Number "$NumberFn" >/dev/null; bl_env_define "$BL_GLOBAL_ENV" num "$NumberFn" >/dev/null
  bl_make_builtin to_int; bl_env_define "$BL_GLOBAL_ENV" int "$RET" >/dev/null
  bl_make_builtin to_float; bl_env_define "$BL_GLOBAL_ENV" float "$RET" >/dev/null
  bl_make_builtin bytes; local BytesFn=$RET; bl_prop_set_key "$BytesFn" prototype "$BL_BYTES_PROTO" >/dev/null; bl_env_define "$BL_GLOBAL_ENV" Bytes "$BytesFn" >/dev/null
  bl_make_builtin to_boolean; local BooleanFn=$RET; bl_env_define "$BL_GLOBAL_ENV" Boolean "$BooleanFn" >/dev/null; bl_env_define "$BL_GLOBAL_ENV" bool "$BooleanFn" >/dev/null

  # JS-shaped global utility objects.
  bl_make_object "$BL_OBJECT_PROTO"; local ObjectObj=$RET
  bl_make_builtin object_create; bl_prop_set_key "$ObjectObj" create "$RET" >/dev/null
  bl_env_lookup "$BL_GLOBAL_ENV" keys; bl_prop_set_key "$ObjectObj" keys "$RET" >/dev/null
  bl_env_lookup "$BL_GLOBAL_ENV" values; bl_prop_set_key "$ObjectObj" values "$RET" >/dev/null
  bl_env_lookup "$BL_GLOBAL_ENV" entries; bl_prop_set_key "$ObjectObj" entries "$RET" >/dev/null
  bl_env_lookup "$BL_GLOBAL_ENV" get-proto; bl_prop_set_key "$ObjectObj" getPrototypeOf "$RET" >/dev/null
  bl_env_lookup "$BL_GLOBAL_ENV" set-proto!; bl_prop_set_key "$ObjectObj" setPrototypeOf "$RET" >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" Object "$ObjectObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; local ArrayObj=$RET
  bl_make_builtin object_is_array; bl_prop_set_key "$ArrayObj" isArray "$RET" >/dev/null
  bl_prop_set_key "$ArrayObj" prototype "$BL_ARRAY_PROTO" >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" Array "$ArrayObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; local MathObj=$RET
  bl_make_builtin math_abs; bl_prop_set_key "$MathObj" abs "$RET" >/dev/null
  bl_make_builtin math_min; bl_prop_set_key "$MathObj" min "$RET" >/dev/null
  bl_make_builtin math_max; bl_prop_set_key "$MathObj" max "$RET" >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" Math "$MathObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; BL_TCP_PROTO=$RET
  for spec in 'write:tcp_write' 'read:tcp_read' 'readLine:tcp_read_line' 'readAll:tcp_read_all' 'close:tcp_close'; do name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl" method; bl_prop_set_key "$BL_TCP_PROTO" "$name" "$RET" >/dev/null; done
  bl_make_object "$BL_OBJECT_PROTO"; BL_FILE_PROTO=$RET
  for spec in 'write:tcp_write' 'read:tcp_read' 'readLine:tcp_read_line' 'readAll:tcp_read_all' 'close:tcp_close'; do name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl" method; bl_prop_set_key "$BL_FILE_PROTO" "$name" "$RET" >/dev/null; done

  bl_make_object "$BL_OBJECT_PROTO"; local NetObj=$RET
  bl_make_builtin tcp_connect; bl_prop_set_key "$NetObj" connect "$RET" >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" net "$NetObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; local EnvObj=$RET
  for spec in 'get:env_get' 'has:env_has' 'set:env_set' 'unset:env_unset'; do name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl"; bl_prop_set_key "$EnvObj" "$name" "$RET" >/dev/null; done
  bl_env_define "$BL_GLOBAL_ENV" env "$EnvObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; local FsObj=$RET
  for spec in 'open:fs_open' 'exists:fs_exists' 'isFile:fs_is_file' 'isDir:fs_is_dir' 'cwd:fs_cwd' 'chdir:fs_chdir' 'mkdir:fs_mkdir' 'remove:fs_remove' 'rename:fs_rename' 'size:fs_size' 'list:fs_list' 'readBytes:read_bytes' 'writeBytes:write_bytes' 'readText:read_file' 'writeText:write_file'; do name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl"; bl_prop_set_key "$FsObj" "$name" "$RET" >/dev/null; done
  bl_env_define "$BL_GLOBAL_ENV" fs "$FsObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; BL_PROCESS_HANDLE_PROTO=$RET
  for spec in 'poll:process_handle_poll' 'wait:process_handle_wait' 'kill:process_handle_kill' 'stdout:process_handle_stdout' 'stderr:process_handle_stderr' 'result:process_handle_result' 'close:process_handle_close'; do name=${spec%%:*}; impl=${spec#*:}; bl_make_builtin "$impl" method; bl_prop_set_key "$BL_PROCESS_HANDLE_PROTO" "$name" "$RET" >/dev/null; done

  bl_make_object "$BL_OBJECT_PROTO"; local ProcessObj=$RET
  bl_make_builtin process_run; bl_prop_set_key "$ProcessObj" run "$RET" >/dev/null
  bl_make_builtin process_spawn; bl_prop_set_key "$ProcessObj" spawn "$RET" >/dev/null
  bl_make_builtin process_which; bl_prop_set_key "$ProcessObj" which "$RET" >/dev/null
  bl_make_int "$$"; bl_prop_set_key "$ProcessObj" pid "$RET" >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" process "$ProcessObj" >/dev/null

  bl_make_object "$BL_FILE_PROTO"; local StdinObj=$RET; bl_make_int 0; bl_prop_set_key "$StdinObj" fd "$RET" >/dev/null; bl_prop_set_key "$StdinObj" closed false >/dev/null; bl_make_string r; bl_prop_set_key "$StdinObj" mode "$RET" >/dev/null
  bl_make_object "$BL_FILE_PROTO"; local StdoutObj=$RET; bl_make_int 1; bl_prop_set_key "$StdoutObj" fd "$RET" >/dev/null; bl_prop_set_key "$StdoutObj" closed false >/dev/null; bl_make_string w; bl_prop_set_key "$StdoutObj" mode "$RET" >/dev/null
  bl_make_object "$BL_FILE_PROTO"; local StderrObj=$RET; bl_make_int 2; bl_prop_set_key "$StderrObj" fd "$RET" >/dev/null; bl_prop_set_key "$StderrObj" closed false >/dev/null; bl_make_string w; bl_prop_set_key "$StderrObj" mode "$RET" >/dev/null
  bl_make_object "$BL_OBJECT_PROTO"; local IoObj=$RET; bl_prop_set_key "$IoObj" stdin "$StdinObj" >/dev/null; bl_prop_set_key "$IoObj" stdout "$StdoutObj" >/dev/null; bl_prop_set_key "$IoObj" stderr "$StderrObj" >/dev/null; bl_env_define "$BL_GLOBAL_ENV" io "$IoObj" >/dev/null

  bl_make_object "$BL_OBJECT_PROTO"; local ConsoleObj=$RET
  bl_env_lookup "$BL_GLOBAL_ENV" println; bl_prop_set_key "$ConsoleObj" log "$RET" >/dev/null
  bl_env_lookup "$BL_GLOBAL_ENV" print; bl_prop_set_key "$ConsoleObj" write "$RET" >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" console "$ConsoleObj" >/dev/null

  # Surface language uses null as spelling for nil and sees a nil-valued this at top level.
  bl_env_define "$BL_GLOBAL_ENV" null nil >/dev/null
  bl_env_define "$BL_GLOBAL_ENV" this nil >/dev/null
}

bl_interpret_source() {
  local src=$1 env=${2:-$BL_GLOBAL_ENV} form
  bl_parse_all "$src" || return
  RET=nil
  for form in "${BL_FORMS[@]}"; do bl_eval "$form" "$env" || return; done
}

bl_runtime_init() {
  BL_TYPE=(); BL_A=(); BL_B=(); BL_C=(); BL_SEQ=0; BL_GENSYM_SEQ=0
  BL_PROP=(); BL_PROTO=(); BL_KEY_COUNT=(); BL_KEY_AT=(); BL_ARR_LEN=(); BL_BYTES_LEN=(); BL_BYTE_AT=()
  BL_OBJECT_PROTO=nil; BL_ARRAY_PROTO=nil; BL_FUNCTION_PROTO=nil; BL_STRING_PROTO=nil; BL_BYTES_PROTO=nil; BL_TCP_PROTO=nil; BL_FILE_PROTO=nil
  BL_ENV_PARENT=(); BL_ENV_BIND=(); BL_ENV_CONST=(); BL_ENV_SEQ=0
  BL_USER_ARGV=(); BL_FLOW=; BL_FLOW_VALUE=nil; BL_THROWN=0; BL_THROW_VALUE=nil; BL_GC_VMARK=(); BL_GC_EMARK=(); BL_GC_LAST_SEQ=0; BL_GC_RUNNING=0
  bl_process_env_init
  bl_install_builtins
}
