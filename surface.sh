#!/usr/bin/env bash
# BLisp-X surface parser: a JS/C-ish syntax that lowers to ordinary BLisp ASTs.
# runtime.sh must already be sourced.

declare -ag SX_TOK_TYPE=() SX_TOK_VAL=() SX_TOK_GAP=() SX_TOK_OFF=()
SX_POS=0
SX_GENSYM=0
SX_CLASS_PARENT=nil
SX_FUNCTION_DEPTH=0
SX_LOOP_DEPTH=0
SX_TOKEN=
SX_DATUM_MODE=0
SX_TRAILING_CLOSURE_ENABLED=1
SX_ARROW_SUPPRESS_POS=-1
SX_SOURCE_NAME='<input>'
SX_SOURCE_TEXT=
SX_TOKEN_OFFSET=0
SX_LAYOUT_DIAG_ACTIVE=0
SX_LAYOUT_LEX_SOURCE=
SX_SOURCE_LINE_BASE=1

# Operator spellings are aliases for one canonical semantic operator.  A word
# spelling and a symbolic spelling must never differ in precedence,
# associativity, short-circuiting, overloading, or lowering.
declare -Ag SX_OPERATOR_CANON=(
  ['+']='add'              [plus]='add'              [add]='add'
  ['-']='sub'              [minus]='sub'             [sub]='sub'
  ['*']='mul'              [times]='mul'             [mul]='mul'
  ['/']='div'              [divided_by]='div'        [div]='div'
  ['%']='mod'              [modulo]='mod'            [mod]='mod'
  ['**']='pow'             [raised_to]='pow'         [pow]='pow'

  ['<']='lt'               [less_than]='lt'          [lt]='lt'
  ['<=']='le'              [at_most]='le'            [le]='le'
  ['>']='gt'               [greater_than]='gt'       [gt]='gt'
  ['>=']='ge'              [at_least]='ge'           [ge]='ge'
  ['==']='eq'              [equals]='eq'            [eq]='eq'
  ['!=']='ne'              [not_equals]='ne'         [ne]='ne'
  ['===']='ident'          [is]='ident'              [ident]='ident'
  ['!==']='nident'         [is_not]='nident'         [nident]='nident'

  ['&&']='and'             [and]='and'
  ['||']='or'              [or]='or'
  ['!']='not'              [not]='not'

  ['&']='band'             [bit_and]='band'          [band]='band'
  ['|']='bor'              [bit_or]='bor'            [bor]='bor'
  ['^']='bxor'             [bit_xor]='bxor'          [bxor]='bxor'
  ['~']='bnot'             [bit_not]='bnot'          [bnot]='bnot'
  ['<<']='shl'             [shift_left]='shl'        [shl]='shl'
  ['>>']='shr'             [shift_right]='shr'       [shr]='shr'

  ['??']='coalesce'        [coalesce]='coalesce'
  ['..']='range_inc'       [through]='range_inc'     [range_inc]='range_inc'
  ['..<']='range_exc'      [before]='range_exc'      [range_exc]='range_exc'
  ['|>']='pipe_first'      [pipe]='pipe_first'       [pipe_first]='pipe_first'
  ['|>>']='pipe_last'      [pipe_last]='pipe_last'

  # ASCII symbolic counterparts for the previously word-only relations.
  # `@` reads as membership/"at/in"; `<:` is conventional subtype/type-membership notation.
  ['@']='in'               [in]='in'
  ['!@']='not_in'          [not_in]='not_in'
  ['<:']='instanceof'      [instanceof]='instanceof'
  ['!<:']='not_instanceof' [not_instanceof]='not_instanceof'
)
SX_OPERATOR=

sx_operator_at() {
  local i=$1 v=${SX_TOK_VAL[$1]-} t=${SX_TOK_TYPE[$1]-eof}
  [[ $t == op || $t == id ]] || { SX_OPERATOR=; return 1; }
  [[ -n $v ]] || { SX_OPERATOR=; return 1; }
  SX_OPERATOR=${SX_OPERATOR_CANON[$v]-}
  [[ -n $SX_OPERATOR ]]
}

sx_accept_operator() {
  local want=$1
  sx_operator_at "$SX_POS" || return 1
  [[ $SX_OPERATOR == "$want" ]] || return 1
  ((SX_POS++)) || true
}

sx_operator_canon_is_infix() {
  case $1 in
    add|sub|mul|div|mod|pow|lt|le|gt|ge|eq|ne|ident|nident|and|or|band|bor|bxor|shl|shr|coalesce|range_inc|range_exc|pipe_first|pipe_last|in|not_in|instanceof|not_instanceof) return 0 ;;
    *) return 1 ;;
  esac
}

sx_error() {
  local near='<eof>'
  (( SX_POS < ${#SX_TOK_VAL[@]} )) && near=${SX_TOK_VAL[SX_POS]}
  local off=${SX_TOK_OFF[SX_POS]-${#SX_SOURCE_TEXT}} line col excerpt
  sx_error_location "$off"
  line=$SX_ERROR_LINE; col=$SX_ERROR_COL
  local display_line=$((line + SX_SOURCE_LINE_BASE - 1))
  sx_source_line "$SX_SOURCE_TEXT" "$line"; excerpt=$SX_ERROR_EXCERPT
  printf '%s:%d:%d: BLisp hybrid parse error: %s (near %q)\n' "$SX_SOURCE_NAME" "$display_line" "$col" "$*" "$near" >&2
  [[ -n $excerpt ]] && {
    printf '  %s\n' "$excerpt" >&2
    printf '  %*s^\n' "$((col-1))" '' >&2
  }
  return 1
}

SX_ERROR_LINE=1
SX_ERROR_COL=1
SX_ERROR_EXCERPT=
sx_line_col_in_source() {
  local src=$1 off=$2 prefix line=1
  (( off < 0 )) && off=0
  (( off > ${#src} )) && off=${#src}
  prefix=${src:0:off}
  while [[ $prefix == *$'\n'* ]]; do prefix=${prefix#*$'\n'}; ((line++)) || true; done
  SX_ERROR_LINE=$line
  SX_ERROR_COL=$((${#prefix}+1))
}

sx_source_line() {
  local src=$1 want=$2 line n=1
  SX_ERROR_EXCERPT=
  while IFS= read -r line || [[ -n $line ]]; do
    if (( n == want )); then SX_ERROR_EXCERPT=$line; return 0; fi
    ((n++)) || true
  done <<< "$src"
}

sx_error_location() {
  local off=$1
  if (( SX_LAYOUT_DIAG_ACTIVE )); then
    sx_line_col_in_source "$SX_LAYOUT_LEX_SOURCE" "$off"
    local rewritten_line=$SX_ERROR_LINE rewritten_col=$SX_ERROR_COL line n=0 i=0 is_marker=0
    while IFS= read -r line || [[ -n $line ]]; do
      ((i++)) || true
      is_marker=0
      [[ $line == *"$SX_LAYOUT_M_NL"* || $line == *"$SX_LAYOUT_M_INDENT"* || $line == *"$SX_LAYOUT_M_DEDENT"* ]] && is_marker=1
      (( ! is_marker )) && ((n++)) || true
      if (( i == rewritten_line )); then
        if (( is_marker )); then SX_ERROR_LINE=$((n+1)); SX_ERROR_COL=1
        else SX_ERROR_LINE=$n; SX_ERROR_COL=$rewritten_col
        fi
        return
      fi
    done <<< "$SX_LAYOUT_LEX_SOURCE"
    SX_ERROR_LINE=$((n+1)); SX_ERROR_COL=1
    return
  fi
  sx_line_col_in_source "$SX_SOURCE_TEXT" "$off"
}

sx_tok() {
  SX_TOK_TYPE+=("$1"); SX_TOK_VAL+=("$2"); SX_TOK_GAP+=("$3"); SX_TOK_OFF+=("$SX_TOKEN_OFFSET")
}

sx_lex() {
  local src=$1 i=0 n=${#1} c d q buf esc op gap=1
  SX_SOURCE_TEXT=$src; SX_LAYOUT_DIAG_ACTIVE=0; SX_LAYOUT_LEX_SOURCE=
  SX_TOK_TYPE=(); SX_TOK_VAL=(); SX_TOK_GAP=(); SX_TOK_OFF=(); SX_POS=0
  while (( i < n )); do
    c=${src:i:1}
    case $c in
      ' '|$'\t'|$'\r'|$'\n') gap=1; ((i++)) || true; continue ;;
    esac
    if [[ $c == / && ${src:i+1:1} == / ]]; then
      gap=1; ((i+=2)) || true
      while ((i<n)) && [[ ${src:i:1} != $'\n' ]]; do ((i++)) || true; done
      continue
    fi
    if [[ $c == / && ${src:i+1:1} == '*' ]]; then
      gap=1; ((i+=2)) || true
      while ((i+1<n)) && ! [[ ${src:i:1} == '*' && ${src:i+1:1} == / ]]; do ((i++)) || true; done
      ((i+1<n)) || { echo 'BLisp hybrid: unterminated block comment' >&2; return 1; }
      ((i+=2)) || true; continue
    fi
    SX_TOKEN_OFFSET=$i
    if [[ $c == b && ( ${src:i+1:1} == '"' || ${src:i+1:1} == "'" ) ]]; then
      q=${src:i+1:1}; ((i+=2)) || true; buf=; local hx ord h1 h2
      while ((i<n)); do
        c=${src:i:1}; ((i++)) || true
        [[ $c == "$q" ]] && break
        if [[ $c == '\' ]]; then
          ((i<n)) || { echo 'BLisp hybrid: unterminated byte escape' >&2; return 1; }
          esc=${src:i:1}; ((i++)) || true
          case $esc in
            n) buf+=0a;; t) buf+=09;; r) buf+=0d;; 0) buf+=00;;
            x)
              ((i+1<n)) || { echo 'BLisp hybrid: short \\x escape' >&2; return 1; }
              h1=${src:i:1}; h2=${src:i+1:1}; [[ $h1$h2 =~ ^[0-9A-Fa-f]{2}$ ]] || { echo 'BLisp hybrid: invalid \\x escape' >&2; return 1; }
              buf+="$h1$h2"; ((i+=2)) || true ;;
            '\') buf+=5c;; '"') buf+=22;; "'") buf+=27;;
            *) printf 'BLisp hybrid: unsupported byte escape \\%s\n' "$esc" >&2; return 1;;
          esac
        else
          [[ $c == [[:ascii:]] ]] 2>/dev/null || true
          LC_ALL=C printf -v ord '%d' "'$c"
          ((ord>=0 && ord<=127)) || { echo 'BLisp hybrid: non-ASCII byte literal text must use \\xHH' >&2; return 1; }
          printf -v hx '%02x' "$ord"; buf+=$hx
        fi
      done
      [[ $c == "$q" ]] || { echo 'BLisp hybrid: unterminated byte literal' >&2; return 1; }
      sx_tok bytes "$buf" "$gap"; gap=0; continue
    fi
    if [[ $c =~ [A-Za-z_$] ]]; then
      buf=
      while ((i<n)) && [[ ${src:i:1} =~ [A-Za-z0-9_$] ]]; do buf+=${src:i:1}; ((i++)) || true; done
      sx_tok id "$buf" "$gap"; gap=0; continue
    fi
    if [[ $c =~ [0-9] ]]; then
      buf=
      if [[ ${src:i:2} =~ ^0[xX]$ ]]; then
        buf=${src:i:2}; ((i+=2)) || true; while ((i<n)) && [[ ${src:i:1} =~ [0-9A-Fa-f_] ]]; do buf+=${src:i:1}; ((i++)) || true; done
      elif [[ ${src:i:2} =~ ^0[bB]$ ]]; then
        buf=${src:i:2}; ((i+=2)) || true; while ((i<n)) && [[ ${src:i:1} =~ [01_] ]]; do buf+=${src:i:1}; ((i++)) || true; done
      elif [[ ${src:i:2} =~ ^0[oO]$ ]]; then
        buf=${src:i:2}; ((i+=2)) || true; while ((i<n)) && [[ ${src:i:1} =~ [0-7_] ]]; do buf+=${src:i:1}; ((i++)) || true; done
      else
        while ((i<n)) && [[ ${src:i:1} =~ [0-9_] ]]; do buf+=${src:i:1}; ((i++)) || true; done
        if ((i<n)) && [[ ${src:i:1} == '.' && ${src:i+1:1} != '.' ]]; then
          buf+='.'; ((i++)) || true; while ((i<n)) && [[ ${src:i:1} =~ [0-9_] ]]; do buf+=${src:i:1}; ((i++)) || true; done
        fi
        if ((i<n)) && [[ ${src:i:1} == e || ${src:i:1} == E ]]; then
          buf+=${src:i:1}; ((i++)) || true; if [[ ${src:i:1} == + || ${src:i:1} == - ]]; then buf+=${src:i:1}; ((i++)) || true; fi
          while ((i<n)) && [[ ${src:i:1} =~ [0-9_] ]]; do buf+=${src:i:1}; ((i++)) || true; done
        fi
      fi
      sx_tok num "$buf" "$gap"; gap=0; continue
    fi
    if [[ $c == '"' || $c == "'" ]]; then
      q=$c; ((i++)) || true; buf=
      while ((i<n)); do
        c=${src:i:1}; ((i++)) || true
        [[ $c == "$q" ]] && break
        if [[ $c == '\' ]]; then
          ((i<n)) || { echo 'BLisp hybrid: unterminated string escape' >&2; return 1; }
          esc=${src:i:1}; ((i++)) || true
          case $esc in
            n) buf+=$'\n';; t) buf+=$'\t';; r) buf+=$'\r';;
            0) echo 'BLisp hybrid: Bash strings cannot contain NUL bytes' >&2; return 1;;
            '\') buf+='\';; '"') buf+='"';; "'") buf+="'";;
            *) buf+="$esc";;
          esac
        else
          buf+="$c"
        fi
      done
      [[ $c == "$q" ]] || { echo 'BLisp hybrid: unterminated string' >&2; return 1; }
      sx_tok str "$buf" "$gap"; gap=0; continue
    fi
    op=
    for d in '!<:' '<<=' '>>=' '...' '..<' '===' '!==' '=>' '**' '|>>' '|>' '?.' '??' '<:' '!@' '<<' '>>' '==' '!=' '<=' '>=' '&&' '||' '++' '--' '+=' '-=' '*=' '/=' '%=' '&=' '|=' '^='; do
      if [[ ${src:i:${#d}} == "$d" ]]; then op=$d; break; fi
    done
    if [[ -n $op ]]; then sx_tok op "$op" "$gap"; gap=0; ((i+=${#op})) || true; continue; fi
    if [[ ${src:i:2} == '..' ]]; then sx_tok op '..' "$gap"; gap=0; ((i+=2)) || true; continue; fi
    case $c in
      '('|')'|'{'|'}'|'['|']'|';'|','|'.'|'?'|':'|'+'|'-'|'*'|'/'|'%'|'!'|'<'|'>'|'='|'|'|'&'|'^'|'@'|'`'|'~')
        sx_tok op "$c" "$gap"; gap=0; ((i++)) || true ;;
      *) printf 'BLisp hybrid lexer: unexpected character %q\n' "$c" >&2; return 1 ;;
    esac
  done
  SX_TOKEN_OFFSET=$n
  sx_tok eof '<eof>' 1
}

sx_is() { [[ ${SX_TOK_VAL[SX_POS]-'<eof>'} == "$1" ]]; }
sx_type_is() { [[ ${SX_TOK_TYPE[SX_POS]-eof} == "$1" ]]; }
sx_accept() { sx_is "$1" || return 1; ((SX_POS++)) || true; }
sx_expect() { sx_accept "$1" || sx_error "expected '$1'"; }
sx_take_type() { sx_type_is "$1" || { sx_error "expected $1"; return 1; }; SX_TOKEN=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true; }
sx_eat_semi() { sx_accept ';' || true; }

sx_sym() { bl_make_symbol "$1"; }
sx_str() { bl_make_string "$1"; }
sx_number_literal() {
  local raw=${1//_/}
  if [[ $raw =~ ^0[xX][0-9A-Fa-f]+$ ]]; then bl_make_int "$((16#${raw:2}))"
  elif [[ $raw =~ ^0[bB][01]+$ ]]; then bl_make_int "$((2#${raw:2}))"
  elif [[ $raw =~ ^0[oO][0-7]+$ ]]; then bl_make_int "$((8#${raw:2}))"
  elif [[ $raw == *.* || $raw == *e* || $raw == *E* ]]; then bl_make_float "$raw"
  else bl_make_int "$((10#$raw))"
  fi
}
sx_form() {
  local name=$1; shift
  bl_make_symbol "$name"; local h=$RET
  bl_list_from_array "$h" "$@"
}
sx_call_ast() { bl_list_from_array "$@"; }
sx_params() { local -a hs=(); local n; for n in "$@"; do bl_make_symbol "$n"; hs+=("$RET"); done; bl_list_from_array "${hs[@]}"; }
sx_params_spec() {
  local rest=${SX_PARAM_REST-} out=nil i
  if [[ -n $rest ]]; then bl_make_symbol "$rest"; out=$RET; fi
  local -a names=("$@")
  for ((i=${#names[@]}-1;i>=0;--i)); do bl_make_symbol "${names[i]}"; bl_cons "$RET" "$out"; out=$RET; done
  RET=$out
}
sx_gensym() { ((++SX_GENSYM)) || true; bl_make_gensym "__sx$SX_GENSYM"; }

# Parentheses have two peer meanings in hybrid source:
#
#   (a + b)     conventional grouping
#   (f a b)     Lisp-style application
#   (+ a b)     Lisp-style prefix application
#
# The distinction is grammatical, not an open-ended heuristic.  After an
# identifier head, whitespace followed by an *expression continuation* keeps
# the form conventional; whitespace followed by a new datum makes it an
# S-expression.  The continuation vocabulary is centralized here so word
# operators (`and`, `or`, `in`, `is`, `instanceof`) cannot silently fall out of
# sync with punctuation operators.  Postfix punctuation only continues an
# expression when it is lexically attached: `(f(x))` groups, while `(f (x))` is
# an S-call.  In particular `(a . b)` remains Lisp dotted-list syntax whereas
# `(a.b)` is property access.
#
# Comments/newlines count as whitespace exactly like spaces.  Explicit parens
# suspend layout indentation, so this rule is independent of layout syntax.
sx_token_is_infix_or_assignment_at() {
  local i=$1 v=${SX_TOK_VAL[$1]-'<eof>'}
  if sx_operator_at "$i" && sx_operator_canon_is_infix "$SX_OPERATOR"; then return 0; fi
  case $v in '='|'+='|'-='|'*='|'/='|'%='|'&='|'|='|'^='|'<<='|'>>='|'?'|'=>') return 0 ;; esac
  return 1
}

sx_token_continues_grouped_head_at() {
  local i=$1; local v=${SX_TOK_VAL[i]-'<eof>'} gap=${SX_TOK_GAP[i]-0}
  sx_token_is_infix_or_assignment_at "$i" && return 0
  case $v in ')'|','|';'|'++'|'--') return 0 ;; esac
  if (( ! gap )); then
    case $v in '('|'['|'.'|'?.') return 0 ;; esac
  fi
  return 1
}

sx_token_is_prefix_sexpr_operator_at() {
  local i=$1
  sx_operator_at "$i" || return 1
  case $SX_OPERATOR in
    add|sub|mul|div|mod|pow|lt|le|gt|ge|eq|ne|ident|nident|and|or|not|band|bor|bxor|bnot|shl|shr|coalesce|pipe_first|pipe_last|in|not_in|instanceof|not_instanceof) return 0 ;;
    *) return 1 ;;
  esac
}

sx_paren_is_sexpr() {
  local head=$((SX_POS + 1)) next=$((SX_POS + 2))
  local ht=${SX_TOK_TYPE[head]-eof}

  # Operator heads are prefix S-forms only when separated from their first
  # argument.  `(-x)` groups unary minus; `(- x)` / `(minus x)` are S-forms.
  if sx_token_is_prefix_sexpr_operator_at "$head"; then
    [[ ${SX_TOK_GAP[next]-0} == 1 && ${SX_TOK_VAL[next]-')'} != ')' ]]
    return
  fi

  [[ $ht == id ]] || return 1
  [[ ${SX_TOK_GAP[next]-0} == 1 ]] || return 1
  sx_token_continues_grouped_head_at "$next" && return 1
  [[ ${SX_TOK_VAL[next]-')'} != ')' ]]
}

sx_operator_ast_symbol() {
  local canon=$1
  case $canon in
    add) sx_sym '+' ;; sub) sx_sym '-' ;; mul) sx_sym '*' ;; div) sx_sym '/' ;; mod) sx_sym '%' ;;
    pow) sx_sym @pow ;;
    lt) sx_sym '<' ;; le) sx_sym '<=' ;; gt) sx_sym '>' ;; ge) sx_sym '>=' ;;
    eq) sx_sym equal? ;; ne) sx_sym not-equal? ;;
    ident) sx_sym eq? ;; nident) sx_sym not-identical? ;;
    and) sx_sym and ;; or) sx_sym or ;; not) sx_sym not ;;
    band) sx_sym '&' ;; bor) sx_sym '|' ;; bxor) sx_sym '^' ;; bnot) sx_sym bit-not ;;
    shl) sx_sym '<<' ;; shr) sx_sym '>>' ;;
    in) sx_sym in ;; not_in) sx_sym not-in ;;
    instanceof) sx_sym instanceof ;; not_instanceof) sx_sym not-instanceof ;;
    coalesce|range_inc|range_exc|pipe_first|pipe_last)
      # These depend on surface-language evaluation/lowering rules and are not
      # exposed as raw prefix runtime operators yet.
      return 1 ;;
    *) return 1 ;;
  esac
}

sx_parse_sexpr_datum() {
  local t=${SX_TOK_TYPE[SX_POS]} v=${SX_TOK_VAL[SX_POS]}
  case $t in
    num) ((SX_POS++)) || true; sx_number_literal "$v" ;;
    bytes) ((SX_POS++)) || true; bl_make_bytes_from_hex "$v" ;;
    str) ((SX_POS++)) || true; bl_make_string "$v" ;;
    id)
      ((SX_POS++)) || true
      case $v in
        true|false) RET=$v ;;
        null|nil) RET=nil ;;
        *)
          local opcanon=${SX_OPERATOR_CANON[$v]-}
          if [[ -n $opcanon ]] && sx_operator_ast_symbol "$opcanon"; then :
          else bl_make_symbol "$v"
          fi ;;
      esac ;;
    op)
      case $v in
        '(')
          if (( SX_DATUM_MODE )) || sx_paren_is_sexpr; then
            sx_parse_sexpr_list
          else
            ((SX_POS++)) || true
            sx_parse_assignment || return
            local grouped=$RET
            sx_expect ')' || return
            RET=$grouped
          fi ;;
        '[') sx_parse_array_literal ;;
        '{') sx_parse_object_literal ;;
        ':')
          ((SX_POS++)) || true
          if sx_type_is id || sx_type_is op; then SX_TOKEN=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true; else sx_error 'expected symbol after :'; return 1; fi
          bl_make_symbol "$SX_TOKEN"; local lit=$RET; sx_form quote "$lit" ;;
        '`')
          ((SX_POS++)) || true
          ((SX_DATUM_MODE++)) || true
          sx_parse_sexpr_datum || { ((SX_DATUM_MODE--)) || true; return; }
          local q=$RET
          ((SX_DATUM_MODE--)) || true
          sx_form quasiquote "$q" ;;
        '~')
          ((SX_POS++)) || true
          local restore_mode=$SX_DATUM_MODE
          (( SX_DATUM_MODE > 0 )) && ((SX_DATUM_MODE--)) || true
          sx_parse_sexpr_datum || { SX_DATUM_MODE=$restore_mode; return; }
          local u=$RET
          SX_DATUM_MODE=$restore_mode
          sx_form unquote "$u" ;;
        *)
          local opcanon=${SX_OPERATOR_CANON[$v]-}
          if [[ -n $opcanon ]] && sx_operator_ast_symbol "$opcanon"; then ((SX_POS++)) || true
          else sx_error "unexpected token in S-expression"; return 1
          fi ;;
      esac ;;
    *) sx_error 'expected S-expression datum'; return 1 ;;
  esac
}

sx_parse_sexpr_list() {
  sx_expect '(' || return
  local -a items=() tail=nil dotted=0
  while ! sx_is ')'; do
    sx_type_is eof && { sx_error 'unterminated S-expression'; return 1; }
    if sx_is '.'; then
      ((${#items[@]})) || { sx_error 'dot before S-expression head'; return 1; }
      ((SX_POS++)) || true
      sx_parse_sexpr_datum || return; tail=$RET; dotted=1
      sx_expect ')' || return
      break
    fi
    sx_parse_sexpr_datum || return; items+=("$RET")
  done
  (( dotted )) || sx_expect ')' || return
  local out=$tail i
  for ((i=${#items[@]}-1;i>=0;--i)); do bl_cons "${items[i]}" "$out"; out=$RET; done
  RET=$out
}

sx_ast_head_is() {
  local ast=$1 want=$2
  [[ ${BL_TYPE[$ast]-} == cons ]] || return 1
  local h=${BL_A[$ast]}
  [[ ${BL_TYPE[$h]-} == symbol && ${BL_A[$h]} == "$want" ]]
}
sx_unpack_get() {
  local ast=$1
  sx_ast_head_is "$ast" @get || return 1
  local r=${BL_B[$ast]}
  bl_nth "$r" 0 || return 1; SX_GET_OBJ=$RET
  bl_nth "$r" 1 || return 1; SX_GET_KEY=$RET
}
SX_GET_OBJ= SX_GET_KEY=

sx_binary() {
  local op=$1 a=$2 b=$3 name
  case $op in
    add) name='+' ;; sub) name='-' ;; mul) name='*' ;; div) name='/' ;; mod) name='%' ;;
    lt) name='<' ;; le) name='<=' ;; gt) name='>' ;; ge) name='>=' ;;
    band) name='&' ;; bor) name='|' ;; bxor) name='^' ;; shl) name='<<' ;; shr) name='>>' ;;
    eq) name='equal?' ;;
    ident) name='eq?' ;;
    and) name='and' ;;
    or) name='or' ;;
    instanceof) name='instanceof' ;;
    in) sx_form has-prop? "$b" "$a"; return ;;
    ne) sx_form equal? "$a" "$b"; local x=$RET; sx_form not "$x"; return ;;
    nident) sx_form eq? "$a" "$b"; local x=$RET; sx_form not "$x"; return ;;
    not_in) sx_form has-prop? "$b" "$a"; local x=$RET; sx_form not "$x"; return ;;
    not_instanceof) sx_form instanceof "$a" "$b"; local x=$RET; sx_form not "$x"; return ;;
    *) sx_error "internal: unknown binary operator $op"; return 1 ;;
  esac
  sx_form "$name" "$a" "$b"
}


sx_make_assignment() {
  local lhs=$1 op=$2 rhs=$3
  if [[ ${BL_TYPE[$lhs]-} == symbol ]]; then
    local name=${BL_A[$lhs]} val=$rhs
    if [[ $op != '=' ]]; then
      local bare=${op%=}; local canon=${SX_OPERATOR_CANON[$bare]-}
      [[ -n $canon ]] || { sx_error "internal: unknown compound assignment $op"; return 1; }
      sx_binary "$canon" "$lhs" "$rhs" || return; val=$RET
    fi
    sx_form set! "$lhs" "$val"; return
  fi
  if sx_unpack_get "$lhs"; then
    local obj=$SX_GET_OBJ key=$SX_GET_KEY
    if [[ $op == '=' ]]; then sx_form set-prop! "$obj" "$key" "$rhs"; return; fi
    # Evaluate computed receiver/key once for compound assignment.
    sx_gensym; local to=$RET; sx_gensym; local tk=$RET
    sx_form @get "$to" "$tk"; local old=$RET
    local bare=${op%=}; local canon=${SX_OPERATOR_CANON[$bare]-}
    [[ -n $canon ]] || { sx_error "internal: unknown compound assignment $op"; return 1; }
    sx_binary "$canon" "$old" "$rhs" || return; local nv=$RET
    sx_form set-prop! "$to" "$tk" "$nv"; local set=$RET
    bl_list_from_array "$to" "$obj"; local bo=$RET
    bl_list_from_array "$tk" "$key"; local bk=$RET
    bl_list_from_array "$bo" "$bk"; local binds=$RET
    sx_form let "$binds" "$set"; return
  fi
  sx_error 'left side of assignment is not assignable'
}

sx_arrow_lookahead() {
  (( SX_POS != SX_ARROW_SUPPRESS_POS )) || return 1
  local save=$SX_POS i=$SX_POS
  SX_ARROW_NAMES=(); SX_ARROW_REST=
  if [[ ${SX_TOK_TYPE[i]} == id && ${SX_TOK_VAL[i+1]-} == '=>' ]]; then
    SX_ARROW_NAMES+=("${SX_TOK_VAL[i]}"); SX_POS=$((i+2)); return 0
  fi
  [[ ${SX_TOK_VAL[i]} == '(' ]] || return 1
  ((i++)) || true
  if [[ ${SX_TOK_VAL[i]} == ')' ]]; then ((i++)) || true
  else
    while :; do
      if [[ ${SX_TOK_VAL[i]} == '...' ]]; then
        ((i++)) || true
        [[ ${SX_TOK_TYPE[i]} == id ]] || { SX_POS=$save; return 1; }
        SX_ARROW_REST=${SX_TOK_VAL[i]}; ((i++)) || true
        [[ ${SX_TOK_VAL[i]} == ')' ]] || { SX_POS=$save; return 1; }
        ((i++)) || true; break
      fi
      [[ ${SX_TOK_TYPE[i]} == id ]] || { SX_POS=$save; return 1; }
      SX_ARROW_NAMES+=("${SX_TOK_VAL[i]}"); ((i++)) || true
      [[ ${SX_TOK_VAL[i]} == ',' ]] && { ((i++)) || true; continue; }
      [[ ${SX_TOK_VAL[i]} == ')' ]] || { SX_POS=$save; return 1; }
      ((i++)) || true; break
    done
  fi
  [[ ${SX_TOK_VAL[i]} == '=>' ]] || { SX_POS=$save; return 1; }
  SX_POS=$((i+1)); return 0
}
declare -ag SX_ARROW_NAMES=()
SX_ARROW_REST=

sx_parse_assignment() {
  local save=$SX_POS
  if sx_arrow_lookahead; then
    local -a names=("${SX_ARROW_NAMES[@]}")
    local SX_PARAM_REST=$SX_ARROW_REST
    sx_params_spec "${names[@]}"; local params=$RET body
    if sx_is '{'; then
      local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH; ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
      sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return; }; body=$RET; SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
    else sx_parse_assignment || return; body=$RET; fi
    sx_form lambda "$params" "$body"; return
  fi
  SX_POS=$save
  sx_parse_conditional || return; local lhs=$RET
  case ${SX_TOK_VAL[SX_POS]} in
    '='|'+='|'-='|'*='|'/='|'%='|'&='|'|='|'^='|'<<='|'>>=')
      local op=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true
      sx_parse_assignment || return; sx_make_assignment "$lhs" "$op" "$RET" ;;
    *) RET=$lhs ;;
  esac
}

sx_parse_conditional() {
  sx_parse_pipe || return; local c=$RET
  if sx_accept '?'; then
    sx_parse_assignment || return; local t=$RET
    sx_expect ':' || return; sx_parse_assignment || return; local f=$RET
    sx_form if "$c" "$t" "$f"
  else RET=$c; fi
}


# Pipelines are an expression-composition primitive, not merely call sugar.
#
#   value |> f            => f(value)
#   value |> f(a)         => f(value, a)
#   value |>> f(a)        => f(a, value)
#   value |> f(a, $, b)   => f(a, value, b)
#   value |> $ * 2 + 1    => value * 2 + 1
#   value |> .trim()      => value.trim()
#   value |> .length      => value.length
#
# `$` is deliberately useful inside an arbitrary stage expression so a pipeline
# does not force every library in existence to put its subject in one blessed
# argument position.
SX_PIPE_HOLES=0
sx_pipe_substitute() {
  local ast=$1 lhs=$2 type=${BL_TYPE[$1]-}
  if [[ $type == symbol && ${BL_A[$ast]} == '$' ]]; then
    ((++SX_PIPE_HOLES)) || true; RET=$lhs; return
  fi
  if [[ $type != cons ]]; then RET=$ast; return; fi

  # Quoted data is data.  A literal `$` inside it is not a pipeline hole.
  local h=${BL_A[$ast]} d=${BL_B[$ast]}
  if [[ ${BL_TYPE[$h]-} == symbol && ${BL_A[$h]} == quote ]]; then RET=$ast; return; fi

  sx_pipe_substitute "$h" "$lhs" || return; local nh=$RET
  sx_pipe_substitute "$d" "$lhs" || return; local nd=$RET
  bl_cons "$nh" "$nd"
}

sx_pipe_special_form() {
  [[ ${BL_TYPE[$1]-} == symbol ]] || return 1
  case ${BL_A[$1]} in
    if|begin|define|set!|lambda|let|and|or|scope|while|for-of|for-c|return|break|continue|quote|@get|set-prop!|delete-prop!) return 0 ;;
  esac
  return 1
}

# Insert the threaded value into an already-parsed call while preserving
# receiver semantics.  Surface `ns.f(a)` is represented as @method-call, so a
# generic list prepend would otherwise turn the receiver into the piped value.
sx_pipe_inject_known_call() {
  local lhs=$1 rhs=$2 side=$3
  [[ ${BL_TYPE[$rhs]-} == cons ]] || return 1
  local head=${BL_A[$rhs]}
  [[ ${BL_TYPE[$head]-} == symbol ]] || return 1
  local name=${BL_A[$head]}
  bl_list_to_array "$rhs" || return 1
  local -a p=("${BL_LIST_RESULT[@]}") out=()
  case $name in
    @method-call)
      ((${#p[@]}>=3)) || return 1
      out=("${p[0]}" "${p[1]}" "${p[2]}")
      if [[ $side == first ]]; then out+=("$lhs" "${p[@]:3}"); else out+=("${p[@]:3}" "$lhs"); fi
      ;;
    call-spread)
      ((${#p[@]}>=2)) || return 1
      sx_form array "$lhs"; local part=$RET
      out=("${p[0]}" "${p[1]}")
      if [[ $side == first ]]; then out+=("$part" "${p[@]:2}"); else out+=("${p[@]:2}" "$part"); fi
      ;;
    @method-call-spread)
      ((${#p[@]}>=3)) || return 1
      sx_form array "$lhs"; local part=$RET
      out=("${p[0]}" "${p[1]}" "${p[2]}")
      if [[ $side == first ]]; then out+=("$part" "${p[@]:3}"); else out+=("${p[@]:3}" "$part"); fi
      ;;
    *) return 1 ;;
  esac
  bl_list_from_array "${out[@]}"
}

sx_pipe_apply_first() {
  local lhs=$1 rhs=$2
  SX_PIPE_HOLES=0; sx_pipe_substitute "$rhs" "$lhs" || return; local filled=$RET
  (( SX_PIPE_HOLES > 0 )) && { RET=$filled; return; }
  if sx_pipe_inject_known_call "$lhs" "$rhs" first; then return; fi
  if [[ ${BL_TYPE[$rhs]-} == cons ]]; then
    local head=${BL_A[$rhs]} rest=${BL_B[$rhs]}
    if ! sx_pipe_special_form "$head"; then
      bl_cons "$lhs" "$rest"; local nr=$RET; bl_cons "$head" "$nr"; return
    fi
  fi
  sx_call_ast "$rhs" "$lhs"
}

sx_pipe_apply_last() {
  local lhs=$1 rhs=$2
  SX_PIPE_HOLES=0; sx_pipe_substitute "$rhs" "$lhs" || return; local filled=$RET
  (( SX_PIPE_HOLES > 0 )) && { RET=$filled; return; }
  if sx_pipe_inject_known_call "$lhs" "$rhs" last; then return; fi
  if [[ ${BL_TYPE[$rhs]-} == cons ]]; then
    local head=${BL_A[$rhs]}
    if ! sx_pipe_special_form "$head"; then
      bl_list_to_array "$rhs" || return
      local -a parts=("${BL_LIST_RESULT[@]}" "$lhs")
      bl_list_from_array "${parts[@]}"; return
    fi
  fi
  sx_call_ast "$rhs" "$lhs"
}

sx_parse_pipe_receiver_stage() {
  local lhs=$1
  sx_expect '.' || return
  sx_take_type id || return; local name=$SX_TOKEN
  sx_str "$name"; local key=$RET
  sx_form @get "$lhs" "$key"; local stage=$RET
  sx_parse_postfix_tail "$stage"
}

sx_parse_pipe() {
  sx_parse_nullish || return; local a=$RET rhs
  while sx_operator_at "$SX_POS" && [[ $SX_OPERATOR == pipe_first || $SX_OPERATOR == pipe_last ]]; do
    local op=$SX_OPERATOR; ((SX_POS++)) || true
    if sx_is '.'; then
      sx_parse_pipe_receiver_stage "$a" || return; a=$RET
      continue
    fi
    sx_parse_nullish || return; rhs=$RET
    if [[ $op == pipe_last ]]; then sx_pipe_apply_last "$a" "$rhs" || return
    else sx_pipe_apply_first "$a" "$rhs" || return
    fi
    a=$RET
  done
  RET=$a
}

sx_parse_nullish() {
  sx_parse_or || return; local a=$RET
  while sx_accept_operator coalesce; do
    sx_parse_or || return; local b=$RET
    sx_gensym; local t=$RET
    sx_form null? "$t"; local cond=$RET
    sx_form if "$cond" "$b" "$t"; local ie=$RET
    bl_list_from_array "$t" "$a"; local pair=$RET; bl_list_from_array "$pair"; local binds=$RET
    sx_form let "$binds" "$ie"; a=$RET
  done
  RET=$a
}

sx_parse_or() {
  sx_parse_and || return; local a=$RET
  while sx_accept_operator or; do sx_parse_and || return; sx_binary or "$a" "$RET"; a=$RET; done
  RET=$a
}
sx_parse_and() {
  sx_parse_bit_or || return; local a=$RET
  while sx_accept_operator and; do sx_parse_bit_or || return; sx_binary and "$a" "$RET"; a=$RET; done
  RET=$a
}
sx_parse_bit_or() {
  sx_parse_bit_xor || return; local a=$RET
  while sx_accept_operator bor; do sx_parse_bit_xor || return; sx_binary bor "$a" "$RET"; a=$RET; done
  RET=$a
}
sx_parse_bit_xor() {
  sx_parse_bit_and || return; local a=$RET
  while sx_accept_operator bxor; do sx_parse_bit_and || return; sx_binary bxor "$a" "$RET"; a=$RET; done
  RET=$a
}
sx_parse_bit_and() {
  sx_parse_equality || return; local a=$RET
  while sx_accept_operator band; do sx_parse_equality || return; sx_binary band "$a" "$RET"; a=$RET; done
  RET=$a
}

sx_parse_equality() {
  sx_parse_relational || return; local a=$RET
  while sx_operator_at "$SX_POS"; do
    local op=$SX_OPERATOR
    case $op in eq|ne|ident|nident) ((SX_POS++)) || true; sx_parse_relational || return; sx_binary "$op" "$a" "$RET" || return; a=$RET ;; *) break ;; esac
  done
  RET=$a
}

sx_parse_relational() {
  sx_parse_range || return; local a=$RET
  while sx_operator_at "$SX_POS"; do
    local op=$SX_OPERATOR
    case $op in lt|le|gt|ge|instanceof|not_instanceof|in|not_in) ((SX_POS++)) || true; sx_parse_range || return; sx_binary "$op" "$a" "$RET" || return; a=$RET ;; *) break ;; esac
  done
  RET=$a
}

sx_parse_range() {
  sx_parse_shift || return; local a=$RET
  if sx_operator_at "$SX_POS" && [[ $SX_OPERATOR == range_inc || $SX_OPERATOR == range_exc ]]; then
    local op=$SX_OPERATOR; ((SX_POS++)) || true
    sx_parse_shift || return; local b=$RET
    [[ $op == range_inc ]] && sx_form range-inclusive "$a" "$b" || sx_form range-exclusive "$a" "$b"
  else RET=$a; fi
}

sx_parse_shift() {
  sx_parse_additive || return; local a=$RET
  while sx_operator_at "$SX_POS" && [[ $SX_OPERATOR == shl || $SX_OPERATOR == shr ]]; do
    local op=$SX_OPERATOR; ((SX_POS++)) || true; sx_parse_additive || return; sx_binary "$op" "$a" "$RET"; a=$RET
  done
  RET=$a
}

sx_parse_additive() {
  sx_parse_multiplicative || return; local a=$RET
  while sx_operator_at "$SX_POS" && [[ $SX_OPERATOR == add || $SX_OPERATOR == sub ]]; do
    local op=$SX_OPERATOR; ((SX_POS++)) || true; sx_parse_multiplicative || return; sx_binary "$op" "$a" "$RET"; a=$RET
  done
  RET=$a
}

sx_parse_multiplicative() {
  sx_parse_exponent || return; local a=$RET
  while sx_operator_at "$SX_POS" && [[ $SX_OPERATOR == mul || $SX_OPERATOR == div || $SX_OPERATOR == mod ]]; do
    local op=$SX_OPERATOR; ((SX_POS++)) || true; sx_parse_exponent || return; sx_binary "$op" "$a" "$RET"; a=$RET
  done
  RET=$a
}

sx_parse_exponent() {
  sx_parse_unary || return; local a=$RET
  if sx_accept_operator pow; then sx_parse_exponent || return; sx_form @pow "$a" "$RET"
  else RET=$a; fi
}

sx_parse_unary() {
  local typ=${SX_TOK_TYPE[SX_POS]} raw=${SX_TOK_VAL[SX_POS]}
  if sx_operator_at "$SX_POS"; then
    local op=$SX_OPERATOR
    case $op in
      not) ((SX_POS++)) || true; sx_parse_unary || return; sx_form not "$RET"; return ;;
      sub) ((SX_POS++)) || true; sx_parse_unary || return; sx_form - "$RET"; return ;;
      bnot) ((SX_POS++)) || true; sx_parse_unary || return; sx_form bit-not "$RET"; return ;;
    esac
  fi
  case "$typ:$raw" in
    'id:typeof') ((SX_POS++)) || true; sx_parse_unary || return; sx_form typeof "$RET" ;;
    'id:delete')
      ((SX_POS++)) || true; sx_parse_unary || return; local x=$RET
      sx_unpack_get "$x" || { sx_error 'delete expects a property/index'; return 1; }
      sx_form delete-prop! "$SX_GET_OBJ" "$SX_GET_KEY" ;;
    'id:new') sx_parse_new || return; sx_parse_postfix_tail "$RET" ;;
    *) sx_parse_postfix ;;
  esac
}

declare -ag SX_ARG_VALUES=() SX_ARG_SPREAD=() SX_ARG_HOLES=()
SX_ARG_HAS_SPREAD=0

sx_parse_call_args() {
  local -a vals=() spreads=() holes=(); local has=0
  if ! sx_is ')'; then
    while :; do
      if sx_type_is op && sx_accept '...'; then
        { sx_type_is op && sx_is '?'; } && { sx_error 'a partial-application hole cannot be spread'; return 1; }
        sx_parse_assignment || return; vals+=("$RET"); spreads+=(1); has=1
      elif sx_type_is op && sx_is '?'; then
        ((SX_POS++)) || true; sx_gensym; vals+=("$RET"); spreads+=(0); holes+=("$RET")
      else
        sx_parse_assignment || return; vals+=("$RET"); spreads+=(0)
      fi
      sx_accept ',' || break
      sx_is ')' && break
    done
  fi
  sx_expect ')' || return
  SX_ARG_VALUES=("${vals[@]}"); SX_ARG_SPREAD=("${spreads[@]}"); SX_ARG_HOLES=("${holes[@]}"); SX_ARG_HAS_SPREAD=$has
}

sx_wrap_call_holes() {
  local call=$1
  ((${#SX_ARG_HOLES[@]})) || { RET=$call; return; }
  local -a names=(); local h
  for h in "${SX_ARG_HOLES[@]}"; do names+=("${BL_A[$h]}"); done
  local SX_PARAM_REST=
  sx_params_spec "${names[@]}"; local params=$RET
  sx_form lambda "$params" "$call"
}


sx_build_arg_parts() {
  SX_ARG_PARTS=(); local i
  for ((i=0;i<${#SX_ARG_VALUES[@]};++i)); do
    if (( SX_ARG_SPREAD[i] )); then SX_ARG_PARTS+=("${SX_ARG_VALUES[i]}")
    else sx_form array "${SX_ARG_VALUES[i]}"; SX_ARG_PARTS+=("$RET"); fi
  done
}
declare -ag SX_ARG_PARTS=()

sx_parse_new() {
  sx_expect new || return
  sx_parse_primary || return; local ctor=$RET
  while sx_accept '.'; do sx_take_type id || return; sx_str "$SX_TOKEN"; local k=$RET; sx_form @get "$ctor" "$k"; ctor=$RET; done
  sx_expect '(' || return
  sx_parse_call_args || return
  if (( SX_ARG_HAS_SPREAD )); then
    sx_build_arg_parts; sx_form new-spread "$ctor" "${SX_ARG_PARTS[@]}"
  else sx_form new-object "$ctor" "${SX_ARG_VALUES[@]}"; fi
}

sx_trailing_lambda_lookahead() {
  (( SX_TRAILING_CLOSURE_ENABLED )) || return 1
  sx_is '{' || return 1
  local i=$((SX_POS + 1))
  [[ ${SX_TOK_VAL[i]-} == '=>' && ${SX_TOK_TYPE[i]-} == op ]] && return 0
  while [[ ${SX_TOK_TYPE[i]-} == id ]]; do
    ((i++)) || true
    if [[ ${SX_TOK_VAL[i]-} == '=>' && ${SX_TOK_TYPE[i]-} == op ]]; then return 0; fi
    [[ ${SX_TOK_VAL[i]-} == ',' && ${SX_TOK_TYPE[i]-} == op ]] || return 1
    ((i++)) || true
  done
  return 1
}

sx_parse_trailing_lambda() {
  sx_expect '{' || return
  local -a names=() forms=()
  if ! sx_is '=>'; then
    while :; do
      sx_take_type id || return; names+=("$SX_TOKEN")
      sx_accept ',' || break
    done
  fi
  sx_expect '=>' || return
  local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH
  ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
  while ! sx_is '}'; do
    sx_type_is eof && { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; sx_error 'unterminated trailing closure'; return 1; }
    sx_parse_statement || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return; }
    forms+=("$RET")
  done
  sx_expect '}' || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return; }
  SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
  local SX_PARAM_REST=
  sx_params_spec "${names[@]}"; local params=$RET
  sx_form scope "${forms[@]}"; local body=$RET
  sx_form lambda "$params" "$body"
}

sx_append_call_arg() {
  local call=$1 arg=$2
  if sx_unpack_get "$call"; then
    sx_form @method-call "$SX_GET_OBJ" "$SX_GET_KEY" "$arg"; return
  fi
  [[ ${BL_TYPE[$call]-} == cons ]] || { sx_call_ast "$call" "$arg"; return; }
  local head=${BL_A[$call]}
  if [[ ${BL_TYPE[$head]-} == symbol ]]; then
    local name=${BL_A[$head]}
    bl_list_to_array "$call" || return
    local -a p=("${BL_LIST_RESULT[@]}")
    case $name in
      @method-call)
        p+=("$arg"); bl_list_from_array "${p[@]}"; return ;;
      call-spread|@method-call-spread)
        sx_form array "$arg"; p+=("$RET"); bl_list_from_array "${p[@]}"; return ;;
      if|begin|define|set!|lambda|let|and|or|scope|while|for-of|for-c|return|break|continue|quote|@get)
        sx_call_ast "$call" "$arg"; return ;;
      *) p+=("$arg"); bl_list_from_array "${p[@]}"; return ;;
    esac
  fi
  # An ordinary call whose callee is itself an expression is still a call; add
  # the closure to that call rather than invoking its result.
  bl_list_to_array "$call" || return; local -a p=("${BL_LIST_RESULT[@]}" "$arg"); bl_list_from_array "${p[@]}"
}

sx_parse_postfix_tail() {
  local x=$1
  while :; do
    if sx_accept '.'; then
      sx_take_type id || return; local name=$SX_TOKEN
      if sx_ast_head_is "$x" @super; then
        local rr=${BL_B[$x]}; bl_nth "$rr" 0 || return; local parent=$RET; sx_str "$name"; local k=$RET; sx_form @superprop "$parent" "$k"; x=$RET
      else
        sx_str "$name"; local k=$RET; sx_form @get "$x" "$k"; x=$RET
      fi
    elif sx_accept '['; then
      # Indexing and slicing share one syntax.  Slices deliberately lower to a
      # normal `slice` method call so user-defined types can participate too.
      if sx_accept ':'; then
        bl_make_int 0; local start=$RET
        sx_str slice; local skey=$RET
        if sx_is ']'; then
          sx_expect ']' || return; sx_form @method-call "$x" "$skey" "$start"; x=$RET
        else
          sx_parse_assignment || return; local end=$RET; sx_expect ']' || return
          sx_form @method-call "$x" "$skey" "$start" "$end"; x=$RET
        fi
      else
        sx_parse_assignment || return; local k=$RET
        if sx_accept ':'; then
          sx_str slice; local skey=$RET
          if sx_is ']'; then
            sx_expect ']' || return; sx_form @method-call "$x" "$skey" "$k"; x=$RET
          else
            sx_parse_assignment || return; local end=$RET; sx_expect ']' || return
            sx_form @method-call "$x" "$skey" "$k" "$end"; x=$RET
          fi
        else
          sx_expect ']' || return; sx_form @get "$x" "$k"; x=$RET
        fi
      fi
    elif sx_is '(' && [[ ${SX_TOK_GAP[SX_POS]-0} == 0 ]]; then
      ((SX_POS++)) || true
      sx_parse_call_args || return
      if (( SX_ARG_HAS_SPREAD )); then sx_build_arg_parts; fi
      if sx_unpack_get "$x"; then
        if (( SX_ARG_HAS_SPREAD )); then sx_form @method-call-spread "$SX_GET_OBJ" "$SX_GET_KEY" "${SX_ARG_PARTS[@]}"; else sx_form @method-call "$SX_GET_OBJ" "$SX_GET_KEY" "${SX_ARG_VALUES[@]}"; fi
        x=$RET
      elif sx_ast_head_is "$x" @super; then
        local rr=${BL_B[$x]}; bl_nth "$rr" 0 || return; local parent=$RET; sx_sym this; local tv=$RET
        if (( SX_ARG_HAS_SPREAD )); then sx_form @super-call-spread "$parent" "$tv" "${SX_ARG_PARTS[@]}"; else sx_form @super-call "$parent" "$tv" "${SX_ARG_VALUES[@]}"; fi
        x=$RET
      elif sx_ast_head_is "$x" @superprop; then
        local rr=${BL_B[$x]}; bl_nth "$rr" 0 || return; local parent=$RET; bl_nth "$rr" 1 || return; local key=$RET; sx_sym this; local tv=$RET
        if (( SX_ARG_HAS_SPREAD )); then sx_form @super-method-spread "$parent" "$tv" "$key" "${SX_ARG_PARTS[@]}"; else sx_form @super-method "$parent" "$tv" "$key" "${SX_ARG_VALUES[@]}"; fi
        x=$RET
      else
        if (( SX_ARG_HAS_SPREAD )); then sx_form call-spread "$x" "${SX_ARG_PARTS[@]}"; else sx_call_ast "$x" "${SX_ARG_VALUES[@]}"; fi
        x=$RET
      fi
      sx_wrap_call_holes "$x" || return; x=$RET
    elif sx_trailing_lambda_lookahead; then
      sx_parse_trailing_lambda || return; local trailing=$RET
      sx_append_call_arg "$x" "$trailing" || return; x=$RET
    elif sx_accept '++'; then
      bl_make_int 1; local one=$RET; sx_make_assignment "$x" '+=' "$one" || return; x=$RET
    elif sx_accept '--'; then
      bl_make_int 1; local one=$RET; sx_make_assignment "$x" '-=' "$one" || return; x=$RET
    else break; fi
  done
  RET=$x
}

sx_parse_postfix() {
  sx_parse_primary || return; sx_parse_postfix_tail "$RET"
}


sx_parse_branch_value() {
  if sx_is '{'; then sx_parse_block; else sx_parse_assignment; fi
}

sx_parse_branch_head() {
  local old=$SX_ARROW_SUPPRESS_POS
  SX_ARROW_SUPPRESS_POS=$SX_POS
  sx_parse_assignment || { SX_ARROW_SUPPRESS_POS=$old; return 1; }
  SX_ARROW_SUPPRESS_POS=$old
}

sx_parse_cond_expr() {
  sx_expect cond || return; sx_expect '{' || return
  local -a conds=() vals=(); local fallback=nil
  while ! sx_is '}'; do
    if sx_is else || sx_is '_'; then
      ((SX_POS++)) || true; sx_expect '=>' || return
      sx_parse_branch_value || return; fallback=$RET; sx_eat_semi
      sx_is '}' || { sx_error 'else must be the last cond branch'; return 1; }
      break
    fi
    sx_parse_branch_head || return; conds+=("$RET")
    sx_expect '=>' || return; sx_parse_branch_value || return; vals+=("$RET"); sx_eat_semi
  done
  sx_expect '}' || return
  local out=$fallback i
  for ((i=${#conds[@]}-1;i>=0;--i)); do sx_form if "${conds[i]}" "${vals[i]}" "$out"; out=$RET; done
  RET=$out
}

sx_parse_match_expr() {
  sx_expect match || return
  sx_parse_assignment || return; local subject=$RET
  sx_expect '{' || return
  sx_gensym; local tmp=$RET
  local -a pats=() vals=(); local fallback=nil
  while ! sx_is '}'; do
    if sx_is else || sx_is '_'; then
      ((SX_POS++)) || true; sx_expect '=>' || return
      sx_parse_branch_value || return; fallback=$RET; sx_eat_semi
      sx_is '}' || { sx_error 'else must be the last match branch'; return 1; }
      break
    fi
    sx_parse_branch_head || return; pats+=("$RET")
    sx_expect '=>' || return; sx_parse_branch_value || return; vals+=("$RET"); sx_eat_semi
  done
  sx_expect '}' || return
  local out=$fallback i
  for ((i=${#pats[@]}-1;i>=0;--i)); do
    sx_form equal? "$tmp" "${pats[i]}"; local c=$RET
    sx_form if "$c" "${vals[i]}" "$out"; out=$RET
  done
  bl_list_from_array "$tmp" "$subject"; local pair=$RET; bl_list_from_array "$pair"; local binds=$RET
  sx_form let "$binds" "$out"
}

sx_parse_primary() {
  local t=${SX_TOK_TYPE[SX_POS]} v=${SX_TOK_VAL[SX_POS]}
  case $t in
    num) ((SX_POS++)) || true; sx_number_literal "$v" ;;
    bytes) ((SX_POS++)) || true; bl_make_bytes_from_hex "$v" ;;
    str) ((SX_POS++)) || true; bl_make_string "$v" ;;
    id)
      case $v in
        true|false) ((SX_POS++)) || true; RET=$v ;;
        null|nil) ((SX_POS++)) || true; RET=nil ;;
        fn|function) sx_parse_fn_expr ;;
        do) ((SX_POS++)) || true; sx_parse_block ;;
        cond) sx_parse_cond_expr ;;
        match) sx_parse_match_expr ;;
        if) sx_parse_if ;;
    when|unless) sx_parse_when_unless ;;
    cond) sx_parse_cond_expr; sx_eat_semi ;;
    match) sx_parse_match_expr; sx_eat_semi ;;
        super)
          ((SX_POS++)) || true
          [[ $SX_CLASS_PARENT != nil ]] || { sx_error 'super used outside derived class'; return 1; }
          sx_form @super "$SX_CLASS_PARENT" ;;
        *) ((SX_POS++)) || true; bl_make_symbol "$v" ;;
      esac ;;
    op)
      case $v in
        '(')
          if sx_paren_is_sexpr; then sx_parse_sexpr_list
          else ((SX_POS++)) || true; sx_parse_assignment || return; local x=$RET; sx_expect ')' || return; RET=$x; fi ;;
        '[') sx_parse_array_literal ;;
        '{') sx_parse_object_literal ;;
        ':')
          ((SX_POS++)) || true
          if sx_type_is id || sx_type_is op; then SX_TOKEN=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true; else sx_error 'expected symbol after :'; return 1; fi
          bl_make_symbol "$SX_TOKEN"; local lit=$RET; sx_form quote "$lit" ;;
        '`')
          ((SX_POS++)) || true
          ((SX_DATUM_MODE++)) || true
          sx_parse_sexpr_datum || { ((SX_DATUM_MODE--)) || true; return; }
          local q=$RET
          ((SX_DATUM_MODE--)) || true
          sx_form quasiquote "$q" ;;
        *) sx_error 'expected expression'; return 1 ;;
      esac ;;
    *) sx_error 'expected expression'; return 1 ;;
  esac
}

sx_parse_param_names() {
  sx_expect '(' || return
  SX_PARAM_NAMES=(); SX_PARAM_DEFAULTS=(); SX_PARAM_REST=
  local seen_default=0 def=
  if ! sx_is ')'; then
    while :; do
      if sx_accept '...'; then
        sx_take_type id || return; SX_PARAM_REST=$SX_TOKEN
        sx_is ')' || { sx_error 'rest parameter must be last'; return 1; }
        break
      fi
      sx_take_type id || return; SX_PARAM_NAMES+=("$SX_TOKEN"); def=
      if sx_accept '='; then
        sx_parse_assignment || return; def=$RET; seen_default=1
      elif (( seen_default )); then
        sx_error 'required parameter may not follow a defaulted parameter'; return 1
      fi
      SX_PARAM_DEFAULTS+=("$def")
      sx_accept ',' || break
    done
  fi
  sx_expect ')'
}
declare -ag SX_PARAM_NAMES=() SX_PARAM_DEFAULTS=()
SX_PARAM_REST=

# Lower surface default parameters into the ordinary Lisp lambda mechanism.
# Defaults are evaluated at *call time*, after required parameters are bound.
# This both keeps the core lambda representation small and avoids Python's
# definition-time mutable-default semantics.
SX_LAMBDA_PARAMS=nil
SX_LAMBDA_BODY=nil
sx_lower_surface_params() {
  local body=$1 i first_default=-1 user_rest=$SX_PARAM_REST
  for ((i=0;i<${#SX_PARAM_DEFAULTS[@]};++i)); do
    [[ -n ${SX_PARAM_DEFAULTS[i]} ]] && { first_default=$i; break; }
  done
  if (( first_default < 0 )); then
    local SX_PARAM_REST=$SX_PARAM_REST
    sx_params_spec "${SX_PARAM_NAMES[@]}"
    SX_LAMBDA_PARAMS=$RET; SX_LAMBDA_BODY=$body; return
  fi

  local -a required=("${SX_PARAM_NAMES[@]:0:first_default}") init=()
  sx_gensym; local restsym=$RET restname=${BL_A[$RET]}
  local SX_PARAM_REST=$restname
  sx_params_spec "${required[@]}"; SX_LAMBDA_PARAMS=$RET

  for ((i=first_default;i<${#SX_PARAM_NAMES[@]};++i)); do
    local name=${SX_PARAM_NAMES[i]} def=${SX_PARAM_DEFAULTS[i]}
    bl_make_symbol "$name"; local nv=$RET
    sx_form null? "$restsym"; local empty=$RET
    sx_form car "$restsym"; local first=$RET
    sx_form if "$empty" "$def" "$first"; local val=$RET
    sx_form define "$nv" "$val"; init+=("$RET")

    sx_form cdr "$restsym"; local tail=$RET
    sx_form if "$empty" "$restsym" "$tail"; local next=$RET
    sx_form set! "$restsym" "$next"; init+=("$RET")
  done

  if [[ -n $user_rest ]]; then
    bl_make_symbol "$user_rest"; local rv=$RET
    sx_form define "$rv" "$restsym"; init+=("$RET")
  else
    sx_form null? "$restsym"; local noextra=$RET
    bl_make_string 'too many positional arguments'; local msg=$RET
    sx_form error "$msg"; local bad=$RET
    sx_form if "$noextra" nil "$bad"; init+=("$RET")
  fi
  init+=("$body")
  sx_form begin "${init[@]}"; SX_LAMBDA_BODY=$RET
}

sx_parse_fn_expr() {
  ((SX_POS++)) || true # fn/function
  # Optional function-expression name is accepted but presently informational.
  if sx_type_is id && [[ ${SX_TOK_VAL[SX_POS+1]-} == '(' ]]; then ((SX_POS++)) || true; fi
  sx_parse_param_names || return
  local -a saved_names=("${SX_PARAM_NAMES[@]}") saved_defaults=("${SX_PARAM_DEFAULTS[@]}"); local saved_rest=$SX_PARAM_REST
  local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH; ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
  sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return; }; local body=$RET
  SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
  SX_PARAM_NAMES=("${saved_names[@]}"); SX_PARAM_DEFAULTS=("${saved_defaults[@]}"); SX_PARAM_REST=$saved_rest
  sx_lower_surface_params "$body" || return; local params=$SX_LAMBDA_PARAMS; body=$SX_LAMBDA_BODY
  sx_form lambda "$params" "$body"
}

sx_parse_array_literal() {
  sx_expect '[' || return
  local -a vals=() spreads=(); local has=0
  if ! sx_is ']'; then
    while :; do
      if sx_accept '...'; then sx_parse_assignment || return; vals+=("$RET"); spreads+=(1); has=1
      else sx_parse_assignment || return; vals+=("$RET"); spreads+=(0); fi
      sx_accept ',' || break; sx_is ']' && break
    done
  fi
  sx_expect ']' || return
  if (( ! has )); then sx_form array "${vals[@]}"; return; fi
  local -a parts=(); local i
  for ((i=0;i<${#vals[@]};++i)); do
    if (( spreads[i] )); then parts+=("${vals[i]}"); else sx_form array "${vals[i]}"; parts+=("$RET"); fi
  done
  sx_form array-spread "${parts[@]}"
}


sx_parse_object_literal() {
  sx_expect '{' || return
  local -a direct=() parts=(); local has_spread=0 key key_ast key_is_id val
  while ! sx_is '}'; do
    if sx_accept '...'; then
      sx_parse_assignment || return; parts+=("$RET"); has_spread=1
    else
      key_is_id=0
      if sx_accept '['; then
        sx_parse_assignment || return; key_ast=$RET; sx_expect ']' || return
      elif sx_type_is id || sx_type_is str || sx_type_is num; then
        key=${SX_TOK_VAL[SX_POS]}; [[ ${SX_TOK_TYPE[SX_POS]} == id ]] && key_is_id=1
        ((SX_POS++)) || true; sx_str "$key"; key_ast=$RET
      else sx_error 'expected object property name, [computed key], or spread'; return 1; fi

      if sx_accept ':'; then
        sx_parse_assignment || return; val=$RET
      elif (( key_is_id )) && sx_is '('; then
        sx_parse_param_names || return
        local -a saved_names=("${SX_PARAM_NAMES[@]}") saved_defaults=("${SX_PARAM_DEFAULTS[@]}"); local saved_rest=$SX_PARAM_REST
        local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH; ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
        sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
        SX_PARAM_NAMES=("${saved_names[@]}"); SX_PARAM_DEFAULTS=("${saved_defaults[@]}"); SX_PARAM_REST=$saved_rest
        sx_lower_surface_params "$body" || return; local params=$SX_LAMBDA_PARAMS; body=$SX_LAMBDA_BODY
        sx_form lambda "$params" "$body"; val=$RET
      elif (( key_is_id )); then
        bl_make_symbol "$key"; val=$RET
      else sx_error 'computed/object literal key requires : value'; return 1; fi

      direct+=("$key_ast" "$val")
      sx_form object "$key_ast" "$val"; parts+=("$RET")
    fi
    sx_accept ',' || break
  done
  sx_expect '}' || return
  if (( has_spread )); then sx_form object-merge "${parts[@]}"; else sx_form object "${direct[@]}"; fi
}


sx_parse_block() {
  sx_expect '{' || return; local -a forms=()
  while ! sx_is '}'; do sx_type_is eof && { sx_error 'unterminated block'; return 1; }; sx_parse_statement || return; forms+=("$RET"); done
  sx_expect '}' || return; sx_form scope "${forms[@]}"
}

sx_make_decl() {
  local kind=$1 namev=$2 val=$3
  if [[ $kind == const ]]; then sx_form define-const "$namev" "$val"; else sx_form define "$namev" "$val"; fi
}

sx_parse_declaration() {
  local kind=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true
  if sx_type_is id; then
    sx_take_type id || return; local name=$SX_TOKEN
    bl_make_symbol "$name"; local nv=$RET val=nil
    if sx_accept '='; then sx_parse_assignment || return; val=$RET; fi
    [[ $kind != const || $val != nil ]] || { sx_error 'const requires an initializer'; return 1; }
    sx_eat_semi; sx_make_decl "$kind" "$nv" "$val"; return
  fi
  if sx_accept '['; then
    local -a names=()
    if ! sx_is ']'; then while :; do sx_take_type id || return; names+=("$SX_TOKEN"); sx_accept ',' || break; done; fi
    sx_expect ']' || return; sx_expect '=' || return; sx_parse_assignment || return; local rhs=$RET; sx_eat_semi
    sx_gensym; local tmp=$RET; sx_form define "$tmp" "$rhs"; local -a forms=("$RET"); local i
    for ((i=0;i<${#names[@]};++i)); do
      bl_make_symbol "${names[i]}"; local n=$RET; bl_make_int "$i"; local ix=$RET; sx_form @get "$tmp" "$ix"; local g=$RET
      sx_make_decl "$kind" "$n" "$g"; forms+=("$RET")
    done
    sx_form begin "${forms[@]}"; return
  fi
  if sx_accept '{'; then
    local -a src_keys=() dst_names=()
    if ! sx_is '}'; then
      while :; do
        sx_take_type id || return; local src=$SX_TOKEN dst=$src
        if sx_accept ':'; then sx_take_type id || return; dst=$SX_TOKEN; fi
        src_keys+=("$src"); dst_names+=("$dst"); sx_accept ',' || break
      done
    fi
    sx_expect '}' || return; sx_expect '=' || return; sx_parse_assignment || return; local rhs=$RET; sx_eat_semi
    sx_gensym; local tmp=$RET; sx_form define "$tmp" "$rhs"; local -a forms=("$RET"); local i
    for ((i=0;i<${#src_keys[@]};++i)); do
      bl_make_symbol "${dst_names[i]}"; local n=$RET; bl_make_string "${src_keys[i]}"; local k=$RET; sx_form @get "$tmp" "$k"; local g=$RET
      sx_make_decl "$kind" "$n" "$g"; forms+=("$RET")
    done
    sx_form begin "${forms[@]}"; return
  fi
  sx_error 'expected variable name or destructuring pattern'
}


sx_parse_fn_decl() {
  ((SX_POS++)) || true
  sx_take_type id || return; local name=$SX_TOKEN
  sx_parse_param_names || return
  local -a saved_names=("${SX_PARAM_NAMES[@]}") saved_defaults=("${SX_PARAM_DEFAULTS[@]}"); local saved_rest=$SX_PARAM_REST
  local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH; ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
  sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
  SX_PARAM_NAMES=("${saved_names[@]}"); SX_PARAM_DEFAULTS=("${saved_defaults[@]}"); SX_PARAM_REST=$saved_rest
  sx_lower_surface_params "$body" || return; local params=$SX_LAMBDA_PARAMS; body=$SX_LAMBDA_BODY
  bl_make_symbol "$name"; local nv=$RET
  sx_form lambda "$params" "$body"; local fn=$RET
  sx_form define "$nv" "$fn"
}

sx_parse_if() {
  sx_expect if || return; sx_expect '(' || return; sx_parse_assignment || return; local c=$RET; sx_expect ')' || return
  sx_parse_statement || return; local t=$RET f=nil
  if sx_accept else; then sx_parse_statement || return; f=$RET; fi
  sx_form if "$c" "$t" "$f"
}

sx_parse_while() {
  sx_expect while || return; sx_expect '(' || return; sx_parse_assignment || return; local c=$RET; sx_expect ')' || return
  local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true; sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_LOOP_DEPTH=$oldld; sx_form while "$c" "$body"
}

sx_parse_loopish() {
  local kind=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true; local cond=true
  if [[ $kind == until ]]; then
    sx_expect '(' || return; sx_parse_assignment || return; local raw=$RET; sx_expect ')' || return
    sx_form not "$raw"; cond=$RET
  fi
  local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true
  sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_LOOP_DEPTH=$oldld
  sx_form while "$cond" "$body"
}

sx_parse_for() {
  sx_expect for || return; sx_expect '(' || return
  # for (let x of iterable)
  if sx_is let || sx_is var || sx_is const; then
    local declkw=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true
    sx_take_type id || return; local name=$SX_TOKEN
    if sx_accept of; then
      sx_parse_assignment || return; local iter=$RET; sx_expect ')' || return; local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true; sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_LOOP_DEPTH=$oldld
      bl_make_symbol "$name"; local nv=$RET; sx_form for-of "$nv" "$iter" "$body"; return
    fi
    if sx_accept in; then
      sx_parse_assignment || return; local obj=$RET; sx_form keys "$obj"; local iter=$RET
      sx_expect ')' || return; local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true; sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_LOOP_DEPTH=$oldld
      bl_make_symbol "$name"; local nv=$RET; sx_form for-of "$nv" "$iter" "$body"; return
    fi
    # C-style declaration initializer.
    bl_make_symbol "$name"; local nv=$RET val=nil
    if sx_accept '='; then sx_parse_assignment || return; val=$RET; fi
    sx_form define "$nv" "$val"; local init=$RET
    sx_expect ';' || return
    local cond=true; if ! sx_is ';'; then sx_parse_assignment || return; cond=$RET; fi; sx_expect ';' || return
    local step=nil; if ! sx_is ')'; then sx_parse_assignment || return; step=$RET; fi; sx_expect ')' || return
    local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true; sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_LOOP_DEPTH=$oldld
    sx_form for-c "$init" "$cond" "$step" "$body"; return
  fi
  local init=nil; if ! sx_is ';'; then sx_parse_assignment || return; init=$RET; fi; sx_expect ';' || return
  local cond=true; if ! sx_is ';'; then sx_parse_assignment || return; cond=$RET; fi; sx_expect ';' || return
  local step=nil; if ! sx_is ')'; then sx_parse_assignment || return; step=$RET; fi; sx_expect ')' || return
  local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true; sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return; }; local body=$RET; SX_LOOP_DEPTH=$oldld
  sx_form for-c "$init" "$cond" "$step" "$body"
}

sx_parse_class() {
  local kind=${SX_TOK_VAL[SX_POS]}; [[ $kind == class || $kind == proto ]] || { sx_error "expected class/proto"; return 1; }
  ((SX_POS++)) || true; sx_take_type id || return; local cname=$SX_TOKEN
  bl_make_symbol "$cname"; local csym=$RET parent=nil
  if sx_accept extends || { [[ $kind == proto ]] && sx_accept ':'; }; then sx_take_type id || return; bl_make_symbol "$SX_TOKEN"; parent=$RET; fi
  sx_expect '{' || return
  local old_parent=$SX_CLASS_PARENT; SX_CLASS_PARENT=$parent
  local ctor_params=nil ctor_body=nil ctor_found=0; local -a meth_names=() meth_params=() meth_bodies=() meth_static=()
  while ! sx_is '}'; do
    local isstatic=0; sx_accept static && isstatic=1
    sx_take_type id || { SX_CLASS_PARENT=$old_parent; return; }; local mname=$SX_TOKEN
    sx_parse_param_names || { SX_CLASS_PARENT=$old_parent; return; }
    local -a saved_names=("${SX_PARAM_NAMES[@]}") saved_defaults=("${SX_PARAM_DEFAULTS[@]}"); local saved_rest=$SX_PARAM_REST
    local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH; ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
    sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; SX_CLASS_PARENT=$old_parent; return; }; local body=$RET; SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
    SX_PARAM_NAMES=("${saved_names[@]}"); SX_PARAM_DEFAULTS=("${saved_defaults[@]}"); SX_PARAM_REST=$saved_rest
    sx_lower_surface_params "$body" || { SX_CLASS_PARENT=$old_parent; return; }; local params=$SX_LAMBDA_PARAMS; body=$SX_LAMBDA_BODY
    if [[ $mname == constructor || $mname == init ]] && (( ! isstatic )); then ctor_params=$params; ctor_body=$body; ctor_found=1
    else meth_names+=("$mname"); meth_params+=("$params"); meth_bodies+=("$body"); meth_static+=("$isstatic"); fi
  done
  sx_expect '}' || { SX_CLASS_PARENT=$old_parent; return; }; SX_CLASS_PARENT=$old_parent
  local -a forms=()
  if (( ! ctor_found )); then
    sx_params; ctor_params=$RET
    if [[ $parent != nil ]]; then sx_sym this; local tv=$RET; sx_form @super-call "$parent" "$tv"; ctor_body=$RET; else ctor_body=nil; fi
  fi
  sx_form lambda "$ctor_params" "$ctor_body"; local ctor=$RET
  sx_form define "$csym" "$ctor"; forms+=("$RET")
  sx_form ensure-prototype "$csym"; local cproto=$RET; forms+=("$cproto")
  if [[ $parent != nil ]]; then
    sx_form ensure-prototype "$parent"; local pproto=$RET; sx_form set-proto! "$cproto" "$pproto"; forms+=("$RET")
    sx_form set-proto! "$csym" "$parent"; forms+=("$RET")
  fi
  local i
  for ((i=0;i<${#meth_names[@]};++i)); do
    sx_form lambda "${meth_params[i]}" "${meth_bodies[i]}"; local fn=$RET; sx_str "${meth_names[i]}"; local k=$RET
    if (( meth_static[i] )); then sx_form set-prop! "$csym" "$k" "$fn"; else sx_form set-prop! "$cproto" "$k" "$fn"; fi
    forms+=("$RET")
  done
  forms+=("$csym")
  sx_form begin "${forms[@]}"
}

sx_parse_when_unless() {
  local kind=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true
  sx_expect '(' || return; sx_parse_assignment || return; local c=$RET; sx_expect ')' || return
  sx_parse_statement || return; local body=$RET
  if [[ $kind == unless ]]; then sx_form not "$c"; c=$RET; fi
  sx_form if "$c" "$body" nil
}

sx_parse_statement() {
  local v=${SX_TOK_VAL[SX_POS]} typ=${SX_TOK_TYPE[SX_POS]}
  if [[ $typ != id && $v != '{' && $v != ';' ]]; then sx_parse_assignment || return; sx_eat_semi; return; fi
  case $v in
    '{') sx_parse_block ;;
    let|var|const) sx_parse_declaration ;;
    fn|function)
      if [[ ${SX_TOK_TYPE[SX_POS+1]-} == id ]]; then sx_parse_fn_decl; else sx_parse_assignment; sx_eat_semi; fi ;;
    class|proto) sx_parse_class ;;
    if) sx_parse_if ;;
    while) sx_parse_while ;;
    loop|until) sx_parse_loopish ;;
    for) sx_parse_for ;;
    return)
      (( SX_FUNCTION_DEPTH > 0 )) || { sx_error 'return outside function'; return 1; }
      ((SX_POS++)) || true; if sx_is ';' || sx_is '}'; then sx_form return; else sx_parse_assignment || return; local x=$RET; sx_form return "$x"; fi; sx_eat_semi ;;
    break) (( SX_LOOP_DEPTH > 0 )) || { sx_error 'break outside loop'; return 1; }; ((SX_POS++)) || true; sx_eat_semi; sx_form break ;;
    continue) (( SX_LOOP_DEPTH > 0 )) || { sx_error 'continue outside loop'; return 1; }; ((SX_POS++)) || true; sx_eat_semi; sx_form continue ;;
    ';') ((SX_POS++)) || true; RET=nil ;;
    *) sx_parse_assignment || return; sx_eat_semi ;;
  esac
}

bl_parse_surface_all() {
  local src=$1 source_name=${2:-${SX_SOURCE_NAME:-'<input>'}} line_base=${3:-1}
  SX_SOURCE_NAME=$source_name; SX_SOURCE_LINE_BASE=$line_base
  sx_lex "$src" || return
  BL_FORMS=(); SX_GENSYM=0; SX_CLASS_PARENT=nil; SX_FUNCTION_DEPTH=0; SX_LOOP_DEPTH=0
  while ! sx_type_is eof; do sx_parse_statement || return; BL_FORMS+=("$RET"); done
}

bl_interpret_surface_source() {
  local src=$1 env=${2:-$BL_GLOBAL_ENV} source_name=${3:-${SX_SOURCE_NAME:-'<input>'}} line_base=${4:-1} form
  bl_parse_surface_all "$src" "$source_name" "$line_base" || return
  RET=nil
  for form in "${BL_FORMS[@]}"; do bl_eval "$form" "$env" || return; [[ -z $BL_FLOW ]] || { echo "BLisp-X: $BL_FLOW outside valid context" >&2; return 1; }; done
}
