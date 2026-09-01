#!/usr/bin/env bash
# Optional layout syntax for BLisp hybrid source.
# Source *after* surface.sh.  This file deliberately wraps the existing parser
# instead of replacing its expression grammar, so explicit syntax remains the
# authority and gains/bugfixes in surface.sh automatically carry over.

# Reserved source markers used only between the layout prepass and sx_lex.
SX_LAYOUT_M_NL='__BLISP_LAYOUT_NL_7f3c__'
SX_LAYOUT_M_INDENT='__BLISP_LAYOUT_INDENT_7f3c__'
SX_LAYOUT_M_DEDENT='__BLISP_LAYOUT_DEDENT_7f3c__'
SX_LAYOUT_REWRITTEN=

# Rename a function that already exists in surface.sh.
sx_layout_alias() {
  local old=$1 new=$2 body
  body=$(declare -f "$old") || { printf 'BLisp layout: missing parser hook %s\n' "$old" >&2; return 1; }
  body=${body/#$old ()/$new ()}
  eval "$body"
}

sx_layout_alias sx_lex sx_lex_without_layout
sx_layout_alias sx_eat_semi sx_eat_semi_without_layout
sx_layout_alias sx_parse_postfix_tail sx_parse_postfix_tail_without_layout
sx_layout_alias sx_parse_block sx_parse_block_without_layout
sx_layout_alias sx_parse_statement sx_parse_statement_without_layout
sx_layout_alias sx_parse_assignment sx_parse_assignment_without_layout
sx_layout_alias sx_parse_if sx_parse_if_without_layout
sx_layout_alias sx_parse_while sx_parse_while_without_layout
sx_layout_alias sx_parse_loopish sx_parse_loopish_without_layout
sx_layout_alias sx_parse_for sx_parse_for_without_layout
sx_layout_alias sx_parse_when_unless sx_parse_when_unless_without_layout
sx_layout_alias sx_parse_class sx_parse_class_without_layout
sx_layout_alias sx_parse_cond_expr sx_parse_cond_expr_without_layout
sx_layout_alias sx_parse_match_expr sx_parse_match_expr_without_layout

# --- textual layout prepass -------------------------------------------------
#
# Only *vertical* whitespace has application meaning.  Horizontal whitespace
# never turns `f x` into a call.  At layout-active depth:
#
#   f
#       a
#       b
#
# is rewritten to a token stream equivalent to a vertical argument group.
# Explicit (), [] and {} suspend layout until they close.  This gives a simple
# mixing rule: explicit delimiters always win locally; layout resumes outside.

sx_layout_starts_continuation() {
  local s=$1 op
  s=${s#"${s%%[![:space:]]*}"}
  for op in '|>>' '|>' '?.' '.' '??' '&&' '||'; do
    [[ $s == "$op"* ]] && return 0
  done
  [[ $s == 'and '* || $s == 'or '* ]]
}

sx_layout_ends_continuation() {
  local s=$1 op
  s=${s%"${s##*[![:space:]]}"}
  # `=>` is intentionally *not* a continuation marker: ending a line with an
  # arrow opens an indented closure body.
  [[ $s == *'=>' ]] && return 1
  for op in '<<=' '>>=' '+=' '-=' '*=' '/=' '%=' '&=' '|=' '^=' '===' '!==' '**' '==' '!=' '<=' '>=' '&&' '||' '<<' '>>' '??' '|>>' '|>' '=' '+' '-' '*' '/' '%' '<' '>' '&' '|' '^' '.' '?' ':' ','; do
    [[ $s == *"$op" ]] && return 0
  done
  return 1
}

# Scan one physical line only for layout-relevant lexical state.  The original
# line is never modified.  Results are published in globals because Bash has no
# tuples and command substitution would lose state in a subshell.
SX_LSCAN_HAS_CODE=0
SX_LSCAN_SIG=
SX_LSCAN_DEPTH=0
SX_LSCAN_QUOTE=
SX_LSCAN_BLOCK_COMMENT=0
sx_layout_scan_line() {
  local line=$1 depth=$2 quote=$3 block=$4
  local i=0 n=${#line} c d esc=0 sig= has=0
  while (( i < n )); do
    c=${line:i:1}; d=${line:i+1:1}
    if (( block )); then
      if [[ $c == '*' && $d == / ]]; then block=0; ((i+=2)) || true; continue; fi
      ((i++)) || true; continue
    fi
    if [[ -n $quote ]]; then
      if (( esc )); then esc=0
      elif [[ $c == '\' ]]; then esc=1
      elif [[ $c == "$quote" ]]; then quote=; fi
      ((i++)) || true; continue
    fi
    if [[ $c == / && $d == / ]]; then break; fi
    if [[ $c == / && $d == '*' ]]; then block=1; ((i+=2)) || true; continue; fi
    if [[ $c == '"' || $c == "'" ]]; then quote=$c; has=1; sig+='S'; ((i++)) || true; continue; fi
    case $c in
      '('|'['|'{') ((depth++)) || true; has=1; sig+=$c ;;
      ')'|']'|'}') (( depth > 0 )) && ((depth--)) || true; has=1; sig+=$c ;;
      ' '|$'\t'|$'\r') sig+=' ' ;;
      *) has=1; sig+=$c ;;
    esac
    ((i++)) || true
  done
  SX_LSCAN_HAS_CODE=$has
  SX_LSCAN_SIG=$sig
  SX_LSCAN_DEPTH=$depth
  SX_LSCAN_QUOTE=$quote
  SX_LSCAN_BLOCK_COMMENT=$block
}

sx_layout_leading_indent() {
  local line=$1 structural=${2:-1} i=0 n=${#1} c
  SX_LAYOUT_INDENT=0
  while (( i < n )); do
    c=${line:i:1}
    if [[ $c == ' ' ]]; then ((SX_LAYOUT_INDENT++)) || true
    elif [[ $c == $'\t' ]]; then
      if (( structural )); then
        printf 'BLisp layout: tabs are not allowed for structural indentation; use spaces\n' >&2
        return 1
      fi
      # Inside explicit delimiters indentation is non-structural.  Do not
      # invent a tab width because the value is deliberately irrelevant.
      ((SX_LAYOUT_INDENT++)) || true
    else break
    fi
    ((i++)) || true
  done
}
SX_LAYOUT_INDENT=0

sx_layout_rewrite_source() {
  local src=$1 line
  [[ $src != *"$SX_LAYOUT_M_NL"* && $src != *"$SX_LAYOUT_M_INDENT"* && $src != *"$SX_LAYOUT_M_DEDENT"* ]] || {
    echo 'BLisp layout: source uses a reserved layout marker identifier' >&2; return 1;
  }

  local out= depth=0 quote= block=0
  local prev_sig= prev_active=0 have_prev=0
  local -a stack=(0)

  # Preserve a final unterminated physical line.
  while IFS= read -r line || [[ -n $line ]]; do
    local depth_before=$depth quote_before=$quote block_before=$block
    local indentation_structural=0
    (( depth_before == 0 )) && [[ -z $quote_before ]] && (( ! block_before )) && indentation_structural=1
    sx_layout_leading_indent "$line" "$indentation_structural" || return
    local indent=$SX_LAYOUT_INDENT

    sx_layout_scan_line "$line" "$depth" "$quote" "$block"
    local has=$SX_LSCAN_HAS_CODE sig=$SX_LSCAN_SIG
    depth=$SX_LSCAN_DEPTH; quote=$SX_LSCAN_QUOTE; block=$SX_LSCAN_BLOCK_COMMENT

    # Blank/comment-only physical lines are invisible to layout.
    if (( ! has )); then out+="$line"$'\n'; continue; fi

    local current_active=0
    (( depth_before == 0 )) && [[ -z $quote_before ]] && (( ! block_before )) && current_active=1

    if (( have_prev && prev_active && current_active )); then
      local top=${stack[${#stack[@]}-1]} continuation=0
      if (( indent >= top )) && { sx_layout_ends_continuation "$prev_sig" || sx_layout_starts_continuation "$sig"; }; then continuation=1; fi

      if (( ! continuation )); then
        if (( indent < top )); then
          while (( ${#stack[@]} > 1 )) && (( indent < stack[${#stack[@]}-1] )); do
            unset 'stack[${#stack[@]}-1]'
            out+=" $SX_LAYOUT_M_DEDENT "
          done
          top=${stack[${#stack[@]}-1]}
          (( indent == top )) || {
            printf 'BLisp layout: inconsistent dedent to column %d; active indentation level is %d\n' "$indent" "$top" >&2
            return 1
          }
          out+=" $SX_LAYOUT_M_NL "$'\n'
        elif (( indent > top )); then
          out+=" $SX_LAYOUT_M_NL $SX_LAYOUT_M_INDENT "$'\n'
          stack+=("$indent")
        else
          out+=" $SX_LAYOUT_M_NL "$'\n'
        fi
      fi
    fi

    out+="$line"$'\n'
    have_prev=1
    prev_sig=$sig
    prev_active=0
    (( depth == 0 )) && [[ -z $quote ]] && (( ! block )) && prev_active=1
  done <<< "$src"

  while (( ${#stack[@]} > 1 )); do
    unset 'stack[${#stack[@]}-1]'
    out+=" $SX_LAYOUT_M_DEDENT "
  done
  (( have_prev )) && out+=" $SX_LAYOUT_M_NL "
  SX_LAYOUT_REWRITTEN=$out
}

# Most existing hybrid source uses explicit delimiters.  Running the Bash
# character-by-character layout scanner over every such module would nearly
# double lexing work.  This conservative line-level check only answers "can
# layout possibly matter?".  A false positive merely takes the slower path; a
# false negative would be incorrect, so the only source we skip is source in
# which every indentation increase follows an explicit opener.  Every layout
# construct needs an indentation increase after a non-opener line.
sx_layout_maybe_needed() {
  local src=$1 line trim prefix indent prev_indent=-1 prev_trim= have_prev=0
  while IFS= read -r line || [[ -n $line ]]; do
    trim=${line#"${line%%[![:space:]]*}"}
    [[ -z $trim || $trim == //* ]] && continue
    prefix=${line%%[![:space:]]*}; indent=${#prefix}
    if (( have_prev && indent > prev_indent )); then
      case $prev_trim in
        *'('|*'['|*'{') ;;
        *) return 0 ;;
      esac
    fi
    prev_indent=$indent; prev_trim=$trim; have_prev=1
  done <<< "$src"
  return 1
}

sx_lex() {
  if ! sx_layout_maybe_needed "$1"; then
    sx_lex_without_layout "$1"
    return
  fi
  sx_layout_rewrite_source "$1" || return
  sx_lex_without_layout "$SX_LAYOUT_REWRITTEN" || return
  local i
  for ((i=0;i<${#SX_TOK_VAL[@]};++i)); do
    case ${SX_TOK_VAL[i]} in
      "$SX_LAYOUT_M_NL") SX_TOK_TYPE[i]=layout; SX_TOK_VAL[i]='<nl>' ;;
      "$SX_LAYOUT_M_INDENT") SX_TOK_TYPE[i]=layout; SX_TOK_VAL[i]='<indent>' ;;
      "$SX_LAYOUT_M_DEDENT") SX_TOK_TYPE[i]=layout; SX_TOK_VAL[i]='<dedent>' ;;
    esac
  done
}

# --- parser hooks -----------------------------------------------------------

sx_is_nl() { [[ ${SX_TOK_TYPE[SX_POS]-} == layout && ${SX_TOK_VAL[SX_POS]-} == '<nl>' ]]; }
sx_is_indent() { [[ ${SX_TOK_TYPE[SX_POS]-} == layout && ${SX_TOK_VAL[SX_POS]-} == '<indent>' ]]; }
sx_is_dedent() { [[ ${SX_TOK_TYPE[SX_POS]-} == layout && ${SX_TOK_VAL[SX_POS]-} == '<dedent>' ]]; }
sx_accept_nl() { sx_is_nl || return 1; ((SX_POS++)) || true; }
sx_accept_indent() { sx_is_indent || return 1; ((SX_POS++)) || true; }
sx_accept_dedent() { sx_is_dedent || return 1; ((SX_POS++)) || true; }
sx_skip_nl() { while sx_accept_nl; do :; done; }
sx_layout_group_ahead() { sx_is_nl && [[ ${SX_TOK_VAL[SX_POS+1]-} == '<indent>' ]]; }

sx_eat_semi() {
  sx_eat_semi_without_layout || return
  sx_skip_nl
}

# Use the same method-call model as explicit parentheses.  If the head is an
# @get expression, vertical application binds the receiver exactly as obj.m().
sx_layout_append_arg() {
  local call=$1 arg=$2
  if sx_unpack_get "$call"; then
    sx_form @method-call "$SX_GET_OBJ" "$SX_GET_KEY" "$arg"; return
  fi
  if [[ ${BL_TYPE[$call]-} == cons ]]; then
    local head=${BL_A[$call]}
    if [[ ${BL_TYPE[$head]-} == symbol ]]; then
      local name=${BL_A[$head]}
      bl_list_to_array "$call" || return
      local -a p=("${BL_LIST_RESULT[@]}")
      case $name in
        @method-call) p+=("$arg"); bl_list_from_array "${p[@]}"; return ;;
        call-spread|@method-call-spread)
          sx_form array "$arg"; p+=("$RET"); bl_list_from_array "${p[@]}"; return ;;
        if|begin|define|set\!|lambda|let|and|or|scope|while|for-of|for-c|return|break|continue|quote|@get)
          sx_call_ast "$call" "$arg"; return ;;
        *) p+=("$arg"); bl_list_from_array "${p[@]}"; return ;;
      esac
    fi
    bl_list_to_array "$call" || return
    local -a p=("${BL_LIST_RESULT[@]}" "$arg")
    bl_list_from_array "${p[@]}"; return
  fi
  sx_call_ast "$call" "$arg"
}

SX_LAYOUT_CALL_ENABLED=1
sx_parse_layout_call_group() {
  local x=$1 count=0
  sx_accept_nl || { sx_error 'expected layout newline'; return 1; }
  sx_accept_indent || { sx_error 'expected layout indentation'; return 1; }
  sx_skip_nl
  while :; do
    if sx_is_dedent; then
      (( count > 0 )) || { sx_error 'empty layout argument group'; return 1; }
      sx_accept_dedent; RET=$x; return
    fi
    sx_type_is eof && { sx_error 'unterminated layout argument group'; return 1; }
    sx_parse_assignment || return
    local arg=$RET
    sx_layout_append_arg "$x" "$arg" || return; x=$RET
    ((count++)) || true
    if sx_is_dedent; then sx_accept_dedent; RET=$x; return; fi
    if sx_is_nl; then sx_skip_nl; continue; fi
    sx_error 'layout arguments must be separated by a logical newline'
    return 1
  done
}

sx_parse_postfix_tail() {
  sx_parse_postfix_tail_without_layout "$1" || return
  local x=$RET
  while (( SX_LAYOUT_CALL_ENABLED )) && sx_layout_group_ahead; do
    sx_parse_layout_call_group "$x" || return; x=$RET
    # Preserve whatever postfix syntax the current surface parser supports.
    sx_parse_postfix_tail_without_layout "$x" || return; x=$RET
  done
  RET=$x
}

# Braces and layout are two spellings for the same lexical scope.  Existing
# callers such as function declarations/do expressions therefore gain layout
# bodies without knowing anything about indentation.
sx_parse_block() {
  if sx_is '{'; then sx_parse_block_without_layout; return; fi
  sx_layout_group_ahead || { sx_error "expected '{' or an indented block"; return 1; }
  sx_accept_nl; sx_accept_indent
  local -a forms=()
  sx_skip_nl
  while ! sx_is_dedent; do
    sx_type_is eof && { sx_error 'unterminated indented block'; return 1; }
    sx_parse_statement || return
    forms+=("$RET")
    sx_skip_nl
  done
  sx_accept_dedent
  sx_form scope "${forms[@]}"
}


# Parse a header expression without allowing the following indented body to be
# mistaken for vertical arguments to the condition itself.
sx_layout_parse_header_expr() {
  local old=$SX_LAYOUT_CALL_ENABLED
  SX_LAYOUT_CALL_ENABLED=0
  sx_parse_assignment || { SX_LAYOUT_CALL_ENABLED=$old; return 1; }
  SX_LAYOUT_CALL_ENABLED=$old
}

# Arrow closures may use an indented full body.  The ordinary parser still
# handles expression-bodied arrows and explicit { ... } bodies unchanged.
sx_parse_assignment() {
  local save=$SX_POS
  if sx_arrow_lookahead; then
    local -a names=("${SX_ARROW_NAMES[@]}")
    local rest=$SX_ARROW_REST
    if sx_layout_group_ahead; then
      local SX_PARAM_REST=$rest
      sx_params_spec "${names[@]}"; local params=$RET
      local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH
      ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
      sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; return 1; }
      local body=$RET
      SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
      sx_form lambda "$params" "$body"
      return
    fi
  fi
  SX_POS=$save
  sx_parse_assignment_without_layout
}

# Both spellings are accepted:
#
#   if (condition) { ... }
#   if condition
#       ...
#
# Parentheses and braces can independently be kept or omitted.  The condition
# has ordinary expression precedence; its physical newline is the delimiter.
sx_parse_if() {
  sx_expect if || return
  local c
  if sx_accept '('; then
    sx_parse_assignment || return; c=$RET; sx_expect ')' || return
  else
    sx_layout_parse_header_expr || return; c=$RET
  fi
  sx_parse_statement || return; local t=$RET f=nil

  # A layout block closes with DEDENT before the newline that precedes else.
  local save=$SX_POS
  sx_skip_nl
  if sx_accept else; then
    sx_parse_statement || return; f=$RET
  else
    SX_POS=$save
  fi
  sx_form if "$c" "$t" "$f"
}

sx_parse_while() {
  sx_expect while || return
  local c
  if sx_accept '('; then sx_parse_assignment || return; c=$RET; sx_expect ')' || return
  else sx_layout_parse_header_expr || return; c=$RET; fi
  local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true
  sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return 1; }
  local body=$RET; SX_LOOP_DEPTH=$oldld
  sx_form while "$c" "$body"
}

sx_parse_when_unless() {
  local kind=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true
  local c
  if sx_accept '('; then sx_parse_assignment || return; c=$RET; sx_expect ')' || return
  else sx_layout_parse_header_expr || return; c=$RET; fi
  sx_parse_statement || return; local body=$RET
  if [[ $kind == unless ]]; then sx_form not "$c"; c=$RET; fi
  sx_form if "$c" "$body" nil
}

sx_parse_loopish() {
  local kind=${SX_TOK_VAL[SX_POS]}
  if [[ $kind == loop ]]; then
    sx_parse_loopish_without_layout
    return
  fi
  # Preserve the old parenthesized until form exactly.
  if [[ ${SX_TOK_VAL[SX_POS+1]-} == '(' ]]; then
    sx_parse_loopish_without_layout
    return
  fi
  sx_expect until || return
  sx_layout_parse_header_expr || return; local raw=$RET
  sx_form not "$raw"; local cond=$RET
  local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true
  sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return 1; }
  local body=$RET; SX_LOOP_DEPTH=$oldld
  sx_form while "$cond" "$body"
}

# The layout form intentionally does not copy JavaScript's odd `for (k in
# obj)` special case into the common syntax.  `of` means generic iteration;
# `in` remains available for key iteration to preserve existing language code.
sx_parse_for() {
  [[ ${SX_TOK_VAL[SX_POS+1]-} == '(' ]] && { sx_parse_for_without_layout; return; }
  sx_expect for || return
  local declkw=let
  if sx_is let || sx_is var || sx_is const; then declkw=${SX_TOK_VAL[SX_POS]}; ((SX_POS++)) || true; fi
  sx_take_type id || return; local name=$SX_TOKEN
  local mode
  if sx_accept of; then mode=of
  elif sx_accept in; then mode=in
  else sx_error "layout for expects 'of' or 'in'"; return 1; fi

  sx_layout_parse_header_expr || return; local iter=$RET
  if [[ $mode == in ]]; then sx_form keys "$iter"; iter=$RET; fi
  local oldld=$SX_LOOP_DEPTH; ((SX_LOOP_DEPTH++)) || true
  sx_parse_statement || { SX_LOOP_DEPTH=$oldld; return 1; }
  local body=$RET; SX_LOOP_DEPTH=$oldld
  bl_make_symbol "$name"; local nv=$RET
  sx_form for-of "$nv" "$iter" "$body"
}

# Control-flow parsers already ask for a statement body.  Seeing NL+INDENT in
# statement position therefore means a block, while the same token pair after
# an ordinary expression is handled above as vertical application.
sx_parse_statement() {
  if sx_layout_group_ahead; then sx_parse_block; return; fi
  sx_skip_nl
  sx_type_is eof && { RET=nil; return; }
  sx_is_dedent && { sx_error 'unexpected dedent'; return 1; }

  # A newline is a real statement boundary, so bare return no longer needs the
  # semicolon that the old newline-insensitive parser used as its only clue.
  if sx_is return && (( SX_FUNCTION_DEPTH > 0 )) && [[ ${SX_TOK_VAL[SX_POS+1]-} == '<nl>' || ${SX_TOK_VAL[SX_POS+1]-} == '<dedent>' || ${SX_TOK_TYPE[SX_POS+1]-} == eof ]]; then
    ((SX_POS++)) || true; sx_form return; sx_eat_semi; return
  fi
  sx_parse_statement_without_layout
}


# --- richer layout forms ----------------------------------------------------
#
# Vertical argument groups are one application, not repeated unary
# applications.  This distinction matters when explicit syntax is mixed in:
#
#   f
#       a
#       b        => f(a, b)
#
#   f(a)
#       b        => (f(a))(b)
#
# Closing explicit call parentheses therefore really close that application.
# Indentation outside them operates on the resulting value.
sx_layout_apply_args() {
  local callee=$1; shift
  local -a args=("$@")
  if sx_unpack_get "$callee"; then
    sx_form @method-call "$SX_GET_OBJ" "$SX_GET_KEY" "${args[@]}"; return
  fi
  if sx_ast_head_is "$callee" @super; then
    local rr=${BL_B[$callee]}; bl_nth "$rr" 0 || return; local parent=$RET
    sx_sym this; local tv=$RET
    sx_form @super-call "$parent" "$tv" "${args[@]}"; return
  fi
  if sx_ast_head_is "$callee" @superprop; then
    local rr=${BL_B[$callee]}; bl_nth "$rr" 0 || return; local parent=$RET
    bl_nth "$rr" 1 || return; local key=$RET
    sx_sym this; local tv=$RET
    sx_form @super-method "$parent" "$tv" "$key" "${args[@]}"; return
  fi
  sx_call_ast "$callee" "${args[@]}"
}

sx_parse_layout_call_group() {
  local callee=$1
  local -a args=()
  sx_accept_nl || { sx_error 'expected layout newline'; return 1; }
  sx_accept_indent || { sx_error 'expected layout indentation'; return 1; }
  sx_skip_nl
  while :; do
    if sx_is_dedent; then
      ((${#args[@]})) || { sx_error 'empty layout argument group'; return 1; }
      sx_accept_dedent
      sx_layout_apply_args "$callee" "${args[@]}"
      return
    fi
    sx_type_is eof && { sx_error 'unterminated layout argument group'; return 1; }
    sx_parse_assignment || return
    args+=("$RET")
    if sx_is_dedent; then
      sx_accept_dedent
      sx_layout_apply_args "$callee" "${args[@]}"
      return
    fi
    if sx_is_nl; then sx_skip_nl; continue; fi
    sx_error 'layout arguments must be separated by a logical newline'
    return 1
  done
}

# Branch bodies can be expressions, explicit blocks, or indented blocks.
sx_parse_branch_value() {
  if sx_is '{' || sx_layout_group_ahead; then sx_parse_block; else sx_parse_assignment; fi
}

# `cond` and `match` are expression forms.  Their layout variants use one
# indentation level for branches and retain `=>` because it makes the
# condition/pattern-to-result boundary explicit without adding braces.
#
#   cond
#       n < 0 => :negative
#       n == 0 => :zero
#       else => :positive
#
# A result may itself be an indented full block after `=>`.
sx_parse_cond_expr() {
  local save=$SX_POS
  [[ ${SX_TOK_VAL[SX_POS+1]-} == '{' ]] && { sx_parse_cond_expr_without_layout; return; }
  sx_expect cond || return
  sx_layout_group_ahead || { SX_POS=$save; sx_parse_cond_expr_without_layout; return; }
  sx_accept_nl; sx_accept_indent; sx_skip_nl
  local -a conds=() vals=(); local fallback=nil saw_else=0
  while ! sx_is_dedent; do
    if sx_is else || sx_is '_'; then
      ((SX_POS++)) || true; sx_expect '=>' || return
      sx_parse_branch_value || return; fallback=$RET; saw_else=1
      sx_skip_nl
      sx_is_dedent || { sx_error 'else must be the last cond branch'; return 1; }
      break
    fi
    sx_layout_parse_header_expr || return; conds+=("$RET")
    sx_expect '=>' || return
    sx_parse_branch_value || return; vals+=("$RET")
    sx_skip_nl
  done
  sx_accept_dedent || { sx_error 'unterminated layout cond'; return 1; }
  local out=$fallback i
  for ((i=${#conds[@]}-1;i>=0;--i)); do sx_form if "${conds[i]}" "${vals[i]}" "$out"; out=$RET; done
  RET=$out
}

sx_parse_match_expr() {
  local save=$SX_POS
  sx_expect match || return
  sx_layout_parse_header_expr || return; local subject=$RET
  if sx_is '{'; then SX_POS=$save; sx_parse_match_expr_without_layout; return; fi
  sx_layout_group_ahead || { sx_error "match expects '{' or an indented branch group"; return 1; }
  sx_accept_nl; sx_accept_indent; sx_skip_nl
  sx_gensym; local tmp=$RET
  local -a pats=() vals=(); local fallback=nil
  while ! sx_is_dedent; do
    if sx_is else || sx_is '_'; then
      ((SX_POS++)) || true; sx_expect '=>' || return
      sx_parse_branch_value || return; fallback=$RET
      sx_skip_nl
      sx_is_dedent || { sx_error 'else must be the last match branch'; return 1; }
      break
    fi
    sx_layout_parse_header_expr || return; pats+=("$RET")
    sx_expect '=>' || return
    sx_parse_branch_value || return; vals+=("$RET")
    sx_skip_nl
  done
  sx_accept_dedent || { sx_error 'unterminated layout match'; return 1; }
  local out=$fallback i
  for ((i=${#pats[@]}-1;i>=0;--i)); do
    sx_form equal? "$tmp" "${pats[i]}"; local c=$RET
    sx_form if "$c" "${vals[i]}" "$out"; out=$RET
  done
  bl_list_from_array "$tmp" "$subject"; local pair=$RET
  bl_list_from_array "$pair"; local binds=$RET
  sx_form let "$binds" "$out"
}

# Convert the parameter scratch state produced by the current surface parser
# into a lambda, preserving newer call-time-default support when available and
# remaining compatible with older snapshots used by development tests.
sx_layout_lower_method_params() {
  local body=$1 rest=$2; shift 2
  local -a names=("$@")
  if declare -F sx_lower_surface_params >/dev/null; then
    SX_PARAM_NAMES=("${names[@]}")
    SX_PARAM_REST=$rest
    SX_PARAM_DEFAULTS=("${SX_LAYOUT_SAVED_DEFAULTS[@]}")
    sx_lower_surface_params "$body" || return
    SX_LAYOUT_PARAMS=$SX_LAMBDA_PARAMS
    SX_LAYOUT_BODY=$SX_LAMBDA_BODY
  else
    local SX_PARAM_REST=$rest
    sx_params_spec "${names[@]}" || return
    SX_LAYOUT_PARAMS=$RET
    SX_LAYOUT_BODY=$body
  fi
}
declare -ag SX_LAYOUT_SAVED_DEFAULTS=()
SX_LAYOUT_PARAMS=nil
SX_LAYOUT_BODY=nil

# `proto` is the preferred spelling, but `class` gets the same layout support
# for compatibility.  Parameter parentheses remain explicit signature syntax;
# indentation replaces the *body* braces, not every punctuation mark in the
# grammar.
sx_parse_class() {
  local save=$SX_POS kind=${SX_TOK_VAL[SX_POS]}
  [[ $kind == class || $kind == proto ]] || { sx_error 'expected class/proto'; return 1; }
  ((SX_POS++)) || true
  sx_take_type id || return; local cname=$SX_TOKEN
  bl_make_symbol "$cname"; local csym=$RET parent=nil
  if sx_accept extends || { [[ $kind == proto ]] && sx_accept ':'; }; then
    sx_take_type id || return; bl_make_symbol "$SX_TOKEN"; parent=$RET
  fi
  if sx_is '{'; then SX_POS=$save; sx_parse_class_without_layout; return; fi
  sx_layout_group_ahead || { sx_error "proto/class expects '{' or an indented method group"; return 1; }
  sx_accept_nl; sx_accept_indent; sx_skip_nl

  local old_parent=$SX_CLASS_PARENT; SX_CLASS_PARENT=$parent
  local ctor_params=nil ctor_body=nil ctor_found=0
  local -a meth_names=() meth_params=() meth_bodies=() meth_static=()
  while ! sx_is_dedent; do
    local isstatic=0; sx_accept static && isstatic=1
    sx_take_type id || { SX_CLASS_PARENT=$old_parent; return; }; local mname=$SX_TOKEN
    sx_parse_param_names || { SX_CLASS_PARENT=$old_parent; return; }
    local -a saved_names=("${SX_PARAM_NAMES[@]}")
    local saved_rest=$SX_PARAM_REST
    SX_LAYOUT_SAVED_DEFAULTS=()
    if declare -p SX_PARAM_DEFAULTS >/dev/null 2>&1; then SX_LAYOUT_SAVED_DEFAULTS=("${SX_PARAM_DEFAULTS[@]}"); fi

    local oldfd=$SX_FUNCTION_DEPTH oldld=$SX_LOOP_DEPTH
    ((SX_FUNCTION_DEPTH++)) || true; SX_LOOP_DEPTH=0
    sx_parse_block || { SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld; SX_CLASS_PARENT=$old_parent; return; }
    local body=$RET; SX_FUNCTION_DEPTH=$oldfd; SX_LOOP_DEPTH=$oldld
    sx_layout_lower_method_params "$body" "$saved_rest" "${saved_names[@]}" || { SX_CLASS_PARENT=$old_parent; return; }
    local params=$SX_LAYOUT_PARAMS; body=$SX_LAYOUT_BODY

    if [[ $mname == constructor || $mname == init ]] && (( ! isstatic )); then
      ctor_params=$params; ctor_body=$body; ctor_found=1
    else
      meth_names+=("$mname"); meth_params+=("$params"); meth_bodies+=("$body"); meth_static+=("$isstatic")
    fi
    sx_skip_nl
  done
  sx_accept_dedent || { SX_CLASS_PARENT=$old_parent; sx_error 'unterminated proto/class layout body'; return 1; }
  SX_CLASS_PARENT=$old_parent

  local -a forms=()
  if (( ! ctor_found )); then
    sx_params; ctor_params=$RET
    if [[ $parent != nil ]]; then
      sx_sym this; local tv=$RET; sx_form @super-call "$parent" "$tv"; ctor_body=$RET
    else ctor_body=nil; fi
  fi
  sx_form lambda "$ctor_params" "$ctor_body"; local ctor=$RET
  sx_form define "$csym" "$ctor"; forms+=("$RET")
  sx_form ensure-prototype "$csym"; local cproto=$RET; forms+=("$cproto")
  if [[ $parent != nil ]]; then
    sx_form ensure-prototype "$parent"; local pproto=$RET
    sx_form set-proto! "$cproto" "$pproto"; forms+=("$RET")
    sx_form set-proto! "$csym" "$parent"; forms+=("$RET")
  fi
  local i
  for ((i=0;i<${#meth_names[@]};++i)); do
    sx_form lambda "${meth_params[i]}" "${meth_bodies[i]}"; local fn=$RET
    sx_str "${meth_names[i]}"; local k=$RET
    if (( meth_static[i] )); then sx_form set-prop! "$csym" "$k" "$fn"
    else sx_form set-prop! "$cproto" "$k" "$fn"; fi
    forms+=("$RET")
  done
  forms+=("$csym")
  sx_form begin "${forms[@]}"
}


# `return` participates in layout as an expression introducer.  A plain
# newline still means bare return, while an indented group is a value-producing
# scope.  This keeps long return expressions forward-growing:
#
#   return
#       render
#           value
#           options
sx_parse_statement() {
  if sx_layout_group_ahead; then sx_parse_block; return; fi
  sx_skip_nl
  sx_type_is eof && { RET=nil; return; }
  sx_is_dedent && { sx_error 'unexpected dedent'; return 1; }

  if sx_is return && (( SX_FUNCTION_DEPTH > 0 )); then
    if [[ ${SX_TOK_VAL[SX_POS+1]-} == '<nl>' && ${SX_TOK_VAL[SX_POS+2]-} == '<indent>' ]]; then
      ((SX_POS++)) || true
      sx_parse_block || return
      local value=$RET
      sx_form return "$value"
      sx_eat_semi
      return
    fi
    if [[ ${SX_TOK_VAL[SX_POS+1]-} == '<nl>' || ${SX_TOK_VAL[SX_POS+1]-} == '<dedent>' || ${SX_TOK_TYPE[SX_POS+1]-} == eof ]]; then
      ((SX_POS++)) || true; sx_form return; sx_eat_semi; return
    fi
  fi
  sx_parse_statement_without_layout
}
