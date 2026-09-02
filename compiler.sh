#!/usr/bin/env bash
# BLisp -> standalone Bash compiler. Requires runtime.sh to have been sourced.

declare -Ag COMP_BUF=()
COMP_TARGET=main
COMP_FN_SEQ=0
COMP_TMP_SEQ=0
COMP_REPLY=
COMP_CONTINUE_MODE=plain
COMP_CONTINUE_STEP=
COMP_CONTINUE_ENV=

comp_reset() {
  COMP_BUF=(); COMP_BUF[main]=
  COMP_TARGET=main; COMP_FN_SEQ=0; COMP_TMP_SEQ=0; COMP_REPLY=; COMP_CONTINUE_MODE=plain; COMP_CONTINUE_STEP=; COMP_CONTINUE_ENV=
COMP_CONTINUE_MODE=plain
COMP_CONTINUE_STEP=
COMP_CONTINUE_ENV=
}

comp_emit() { COMP_BUF[$COMP_TARGET]+="$1"$'\n'; }
comp_q() { printf -v COMP_REPLY '%q' "$1"; }
comp_temp() { ((++COMP_TMP_SEQ)) || true; COMP_REPLY="__t$COMP_TMP_SEQ"; }

comp_quote_value() {
  local v=$1
  case $v in nil|true|false) comp_emit "RET=$v"; return;; esac
  case ${BL_TYPE[$v]-} in
    int) comp_emit "bl_make_int ${BL_A[$v]}" ;;
    float) comp_q "${BL_A[$v]}"; comp_emit "bl_make_float $COMP_REPLY" ;;
    bytes)
      local __i __n=${BL_BYTES_LEN[$v]-0} __hex= __hx
      for ((__i=0;__i<__n;++__i)); do printf -v __hx '%02x' "${BL_BYTE_AT["$v|$__i"]}"; __hex+=$__hx; done
      comp_q "$__hex"; comp_emit "bl_make_bytes_from_hex $COMP_REPLY" ;;
    string) bl_string_hex "$v" || return; comp_q "$RET"; comp_emit "bl_make_string_from_hex $COMP_REPLY" ;;
    symbol) comp_q "${BL_A[$v]}"; comp_emit "bl_make_symbol $COMP_REPLY" ;;
    cons)
      comp_quote_value "${BL_A[$v]}" || return
      comp_temp; local a=$COMP_REPLY; comp_emit "local $a=\$RET"
      comp_quote_value "${BL_B[$v]}" || return
      comp_temp; local d=$COMP_REPLY; comp_emit "local $d=\$RET"
      comp_emit "bl_cons \"\$$a\" \"\$$d\""
      ;;
    *) echo 'BLisp compiler: cannot quote this value' >&2; return 1 ;;
  esac
}

comp_lambda_parts() {
  local params=$1 body=$2 capture_env=$3
  ((++COMP_FN_SEQ)) || true
  local fn="bl_compiled_fn_$COMP_FN_SEQ"
  local oldtarget=$COMP_TARGET target="fn$COMP_FN_SEQ"
  COMP_TARGET=$target; COMP_BUF[$target]=
  local __old_cont_mode=$COMP_CONTINUE_MODE __old_cont_step=$COMP_CONTINUE_STEP __old_cont_env=$COMP_CONTINUE_ENV
  COMP_CONTINUE_MODE=plain; COMP_CONTINUE_STEP=; COMP_CONTINUE_ENV=

  local -a pnames=()
  local curp=$params pv restname=
  while [[ ${BL_TYPE[$curp]-} == cons ]]; do
    pv=${BL_A[$curp]}
    [[ ${BL_TYPE[$pv]-} == symbol ]] || { echo 'BLisp compiler: lambda parameter must be symbol' >&2; return 1; }
    pnames+=("${BL_A[$pv]}")
    curp=${BL_B[$curp]}
  done
  if [[ $curp != nil ]]; then
    [[ ${BL_TYPE[$curp]-} == symbol ]] || { echo 'BLisp compiler: malformed lambda parameter list' >&2; return 1; }
    restname=${BL_A[$curp]}
  fi

  comp_emit "$fn() {"
  comp_emit '  local __parent=$1 __this=$2; shift 2'
  if [[ -n $restname ]]; then
    comp_emit "  (( \$# >= ${#pnames[@]} )) || { echo \"BLisp: arity mismatch: expected at least ${#pnames[@]}, got \$#\" >&2; return 1; }"
  else
    comp_emit "  (( \$# == ${#pnames[@]} )) || { echo \"BLisp: arity mismatch: expected ${#pnames[@]}, got \$#\" >&2; return 1; }"
  fi
  comp_emit '  bl_env_new "$__parent"; local ENV=$RET'
  comp_emit '  bl_env_define "$ENV" this "$__this" >/dev/null'
  local i q pos
  for ((i=0;i<${#pnames[@]};++i)); do
    comp_q "${pnames[i]}"; q=$COMP_REPLY; pos=$((i + 1))
    comp_emit "  bl_env_define \"\$ENV\" $q \"\$$pos\""
  done
  if [[ -n $restname ]]; then
    local start=$(( ${#pnames[@]} + 1 ))
    comp_emit "  local -a __rest=(\"\${@:$start}\")"
    comp_emit '  bl_list_from_array "${__rest[@]}"; local __restv=$RET'
    comp_q "$restname"; q=$COMP_REPLY
    comp_emit "  bl_env_define \"\$ENV\" $q \"\$__restv\" >/dev/null"
  fi
  local cur=$body
  if [[ $cur == nil ]]; then comp_emit '  RET=nil'; else
    while [[ $cur != nil ]]; do
      [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp compiler: malformed lambda body' >&2; return 1; }
      comp_expr "${BL_A[$cur]}" ENV || return
      cur=${BL_B[$cur]}
    done
  fi
  comp_emit '}'
  COMP_TARGET=$oldtarget
  COMP_CONTINUE_MODE=$__old_cont_mode; COMP_CONTINUE_STEP=$__old_cont_step; COMP_CONTINUE_ENV=$__old_cont_env

  # Emit closure construction through the same callable initializer used by
  # the interpreter; compiled lambdas therefore cannot miss Function.prototype.
  comp_q "$fn"; local __fnq=$COMP_REPLY
  comp_emit "bl_make_compiled $__fnq \"\$$capture_env\""
}

comp_expr() {
  local expr=$1 envvar=$2 type
  case $expr in nil|true|false) comp_emit "RET=$expr"; return;; esac
  type=${BL_TYPE[$expr]-}
  case $type in
    int) comp_emit "bl_make_int ${BL_A[$expr]}"; return ;;
    float) comp_q "${BL_A[$expr]}"; comp_emit "bl_make_float $COMP_REPLY"; return ;;
    bytes)
      local __i __n=${BL_BYTES_LEN[$expr]-0} __hex= __hx
      for ((__i=0;__i<__n;++__i)); do printf -v __hx '%02x' "${BL_BYTE_AT["$expr|$__i"]}"; __hex+=$__hx; done
      comp_q "$__hex"; comp_emit "bl_make_bytes_from_hex $COMP_REPLY"; return ;;
    string) bl_string_hex "$expr" || return; comp_q "$RET"; comp_emit "bl_make_string_from_hex $COMP_REPLY"; return ;;
    symbol) comp_q "${BL_A[$expr]}"; comp_emit "bl_env_lookup \"\$$envvar\" $COMP_REPLY || return 1"; return ;;
    cons) ;;
    *) echo "BLisp compiler: invalid AST value $expr" >&2; return 1 ;;
  esac

  local head=${BL_A[$expr]} rest=${BL_B[$expr]} name
  if [[ ${BL_TYPE[$head]-} == symbol ]]; then
    name=${BL_A[$head]}
    case $name in
      quote)
        bl_nth "$rest" 0 || { echo 'BLisp compiler: quote expects argument' >&2; return 1; }
        comp_quote_value "$RET"; return ;;
      quasiquote)
        bl_nth "$rest" 0 || { echo 'BLisp compiler: quasiquote expects argument' >&2; return 1; }
        comp_quote_value "$RET" || return
        comp_temp; local qt=$COMP_REPLY; comp_emit "local $qt=\$RET"
        comp_emit "bl_eval_quasiquote \"\$$qt\" \"\$$envvar\" || return \$?"
        return ;;
      eval)
        bl_nth "$rest" 0 || { echo 'BLisp compiler: eval expects argument' >&2; return 1; }
        comp_expr "$RET" "$envvar" || return
        comp_temp; local et=$COMP_REPLY; comp_emit "local $et=\$RET"
        comp_emit "bl_eval \"\$$et\" \"\$$envvar\" || return \$?"
        return ;;
      if)
        bl_nth "$rest" 0 || return 1; local ce=$RET
        bl_nth "$rest" 1 || return 1; local te=$RET
        if bl_nth "$rest" 2; then local fe=$RET; else local fe=nil; fi
        comp_expr "$ce" "$envvar" || return
        comp_temp; local ct=$COMP_REPLY; comp_emit "local $ct=\$RET"
        comp_emit "if bl_truthy \"\$$ct\"; then"
        comp_expr "$te" "$envvar" || return
        comp_emit 'else'
        comp_expr "$fe" "$envvar" || return
        comp_emit 'fi'
        return ;;
      begin)
        local bc=$rest
        if [[ $bc == nil ]]; then comp_emit 'RET=nil'; else
          while [[ $bc != nil ]]; do comp_expr "${BL_A[$bc]}" "$envvar" || return; bc=${BL_B[$bc]}; done
        fi
        return ;;
      define)
        bl_nth "$rest" 0 || return 1; local target=$RET
        if [[ ${BL_TYPE[$target]-} == cons ]]; then
          local fnamev=${BL_A[$target]} params=${BL_B[$target]}
          [[ ${BL_TYPE[$fnamev]-} == symbol ]] || { echo 'BLisp compiler: bad define' >&2; return 1; }
          bl_rest "$rest"; local body=$RET
          comp_lambda_parts "$params" "$body" "$envvar" || return
          comp_temp; local cv=$COMP_REPLY; comp_emit "local $cv=\$RET"
          comp_q "${BL_A[$fnamev]}"; comp_emit "bl_env_define \"\$$envvar\" $COMP_REPLY \"\$$cv\""
        else
          [[ ${BL_TYPE[$target]-} == symbol ]] || { echo 'BLisp compiler: define target must be symbol' >&2; return 1; }
          bl_nth "$rest" 1 || return 1; local ve=$RET
          comp_expr "$ve" "$envvar" || return
          comp_temp; local vv=$COMP_REPLY; comp_emit "local $vv=\$RET"
          comp_q "${BL_A[$target]}"; comp_emit "bl_env_define \"\$$envvar\" $COMP_REPLY \"\$$vv\""
        fi
        return ;;
      define-const)
        bl_nth "$rest" 0 || return 1; local cv=$RET
        [[ ${BL_TYPE[$cv]-} == symbol ]] || { echo 'BLisp compiler: const target must be symbol' >&2; return 1; }
        bl_nth "$rest" 1 || return 1; local ce=$RET
        comp_expr "$ce" "$envvar" || return
        comp_temp; local ct=$COMP_REPLY; comp_emit "local $ct=\$RET"
        comp_q "${BL_A[$cv]}"; comp_emit "bl_env_define_const \"\$$envvar\" $COMP_REPLY \"\$$ct\""
        return ;;
      set!)
        bl_nth "$rest" 0 || return 1; local sv=$RET
        [[ ${BL_TYPE[$sv]-} == symbol ]] || { echo 'BLisp compiler: set! target must be symbol' >&2; return 1; }
        bl_nth "$rest" 1 || return 1; local se=$RET
        comp_expr "$se" "$envvar" || return
        comp_temp; local st=$COMP_REPLY; comp_emit "local $st=\$RET"
        comp_q "${BL_A[$sv]}"; comp_emit "bl_env_set \"\$$envvar\" $COMP_REPLY \"\$$st\" || return 1"
        return ;;
      lambda)
        bl_nth "$rest" 0 || return 1; local params=$RET
        bl_rest "$rest"; local body=$RET
        comp_lambda_parts "$params" "$body" "$envvar"; return ;;
      let)
        bl_nth "$rest" 0 || return 1; local binds=$RET
        bl_rest "$rest"; local body=$RET
        local -a names=() vals=() valtemps=()
        local cur=$binds pair nv vv
        while [[ $cur != nil ]]; do
          pair=${BL_A[$cur]}; bl_nth "$pair" 0 || return 1; nv=$RET; bl_nth "$pair" 1 || return 1; vv=$RET
          [[ ${BL_TYPE[$nv]-} == symbol ]] || { echo 'BLisp compiler: let binding name must be symbol' >&2; return 1; }
          names+=("${BL_A[$nv]}"); vals+=("$vv"); cur=${BL_B[$cur]}
        done
        for vv in "${vals[@]}"; do comp_expr "$vv" "$envvar" || return; comp_temp; valtemps+=("$COMP_REPLY"); comp_emit "local ${valtemps[-1]}=\$RET"; done
        comp_temp; local le=$COMP_REPLY; comp_emit "bl_env_new \"\$$envvar\"; local $le=\$RET"
        local i q
        for ((i=0;i<${#names[@]};++i)); do comp_q "${names[i]}"; q=$COMP_REPLY; comp_emit "bl_env_define \"\$$le\" $q \"\$${valtemps[i]}\""; done
        if [[ $body == nil ]]; then comp_emit 'RET=nil'; else while [[ $body != nil ]]; do comp_expr "${BL_A[$body]}" "$le" || return; body=${BL_B[$body]}; done; fi
        return ;;
      and)
        comp_temp; local at=$COMP_REPLY; comp_emit "local $at=true"
        local ac=$rest
        while [[ $ac != nil ]]; do
          comp_emit "if bl_truthy \"\$$at\"; then"
          comp_expr "${BL_A[$ac]}" "$envvar" || return
          comp_emit "  $at=\$RET"
          comp_emit 'fi'
          ac=${BL_B[$ac]}
        done
        comp_emit "RET=\$$at"; return ;;
      or)
        comp_temp; local ot=$COMP_REPLY; comp_emit "local $ot=false"
        local oc=$rest
        while [[ $oc != nil ]]; do
          comp_emit "if ! bl_truthy \"\$$ot\"; then"
          comp_expr "${BL_A[$oc]}" "$envvar" || return
          comp_emit "  $ot=\$RET"
          comp_emit 'fi'
          oc=${BL_B[$oc]}
        done
        comp_emit "RET=\$$ot"; return ;;
      scope)
        comp_temp; local scenv=$COMP_REPLY
        comp_emit "bl_env_new \"\$$envvar\"; local $scenv=\$RET"
        local scc=$rest
        if [[ $scc == nil ]]; then comp_emit 'RET=nil'; else while [[ $scc != nil ]]; do comp_expr "${BL_A[$scc]}" "$scenv" || return; scc=${BL_B[$scc]}; done; fi
        return ;;
      while)
        bl_nth "$rest" 0 || return 1; local wce=$RET
        bl_rest "$rest" || return 1; local wb=$RET
        comp_emit 'while :; do'
        comp_expr "$wce" "$envvar" || return
        comp_temp; local wct=$COMP_REPLY; comp_emit "local $wct=\$RET"
        comp_emit "bl_truthy \"\$$wct\" || break"
        local __ocm=$COMP_CONTINUE_MODE __ocs=$COMP_CONTINUE_STEP __oce=$COMP_CONTINUE_ENV
        COMP_CONTINUE_MODE=plain; COMP_CONTINUE_STEP=; COMP_CONTINUE_ENV=
        local wcur=$wb
        while [[ $wcur != nil ]]; do comp_expr "${BL_A[$wcur]}" "$envvar" || return; wcur=${BL_B[$wcur]}; done
        COMP_CONTINUE_MODE=$__ocm; COMP_CONTINUE_STEP=$__ocs; COMP_CONTINUE_ENV=$__oce
        comp_emit 'done'
        comp_emit 'RET=nil'
        return ;;
      for-of)
        bl_nth "$rest" 0 || return 1; local fvar=$RET
        [[ ${BL_TYPE[$fvar]-} == symbol ]] || { echo 'BLisp compiler: for-of variable must be symbol' >&2; return 1; }
        bl_nth "$rest" 1 || return 1; local fexpr=$RET
        bl_rest "$rest" || return 1; local frr=$RET; bl_rest "$frr" || return 1; local fbody=$RET
        comp_expr "$fexpr" "$envvar" || return
        comp_emit 'bl_iter_begin "$RET" || return 1'
        comp_temp; local fit=$COMP_REPLY; comp_emit "local $fit=\$RET"
        comp_temp; local fval=$COMP_REPLY; comp_emit "local $fval"
        comp_emit 'while :; do'
        comp_emit "  bl_iter_next \"\$$fit\" || return 1"
        comp_emit '  ((BL_ITER_DONE)) && break'
        comp_emit "  $fval=\$RET"
        comp_temp; local fenv=$COMP_REPLY; comp_emit "  bl_env_new \"\$$envvar\"; local $fenv=\$RET"
        comp_q "${BL_A[$fvar]}"; local fq=$COMP_REPLY; comp_emit "  bl_env_define \"\$$fenv\" $fq \"\$$fval\" >/dev/null"
        local __ocm=$COMP_CONTINUE_MODE __ocs=$COMP_CONTINUE_STEP __oce=$COMP_CONTINUE_ENV
        COMP_CONTINUE_MODE=plain; COMP_CONTINUE_STEP=; COMP_CONTINUE_ENV=
        local fcur=$fbody
        while [[ $fcur != nil ]]; do comp_expr "${BL_A[$fcur]}" "$fenv" || return; fcur=${BL_B[$fcur]}; done
        COMP_CONTINUE_MODE=$__ocm; COMP_CONTINUE_STEP=$__ocs; COMP_CONTINUE_ENV=$__oce
        comp_emit 'done'
        comp_emit 'RET=nil'
        return ;;
      return)
        if [[ $rest == nil ]]; then comp_emit 'RET=nil'; else bl_nth "$rest" 0 || return 1; comp_expr "$RET" "$envvar" || return; fi
        comp_emit 'return 0'
        return ;;
      for-c)
        bl_nth "$rest" 0 || return 1; local fcinit=$RET
        bl_nth "$rest" 1 || return 1; local fccond=$RET
        bl_nth "$rest" 2 || return 1; local fcstep=$RET
        bl_nth "$rest" 3 || return 1; local fcbody=$RET
        [[ $fcinit == nil ]] || { comp_expr "$fcinit" "$envvar" || return; }
        comp_emit 'while :; do'
        if [[ $fccond != true ]]; then comp_expr "$fccond" "$envvar" || return; comp_temp; local fcct=$COMP_REPLY; comp_emit "local $fcct=\$RET"; comp_emit "bl_truthy \"\$$fcct\" || break"; fi
        local __ocm=$COMP_CONTINUE_MODE __ocs=$COMP_CONTINUE_STEP __oce=$COMP_CONTINUE_ENV
        COMP_CONTINUE_MODE=forc; COMP_CONTINUE_STEP=$fcstep; COMP_CONTINUE_ENV=$envvar
        comp_expr "$fcbody" "$envvar" || return
        COMP_CONTINUE_MODE=$__ocm; COMP_CONTINUE_STEP=$__ocs; COMP_CONTINUE_ENV=$__oce
        [[ $fcstep == nil ]] || { comp_expr "$fcstep" "$envvar" || return; }
        comp_emit 'done'
        comp_emit 'RET=nil'
        return ;;
      break) comp_emit 'RET=nil'; comp_emit 'break'; return ;;
      continue)
        comp_emit 'RET=nil'
        if [[ $COMP_CONTINUE_MODE == forc && $COMP_CONTINUE_STEP != nil && -n $COMP_CONTINUE_STEP ]]; then comp_expr "$COMP_CONTINUE_STEP" "$COMP_CONTINUE_ENV" || return; fi
        comp_emit 'continue'; return ;;
    esac
  fi

  comp_expr "$head" "$envvar" || return
  comp_temp; local ft=$COMP_REPLY; comp_emit "local $ft=\$RET"
  local -a args=(); local cur=$rest av
  while [[ $cur != nil ]]; do
    [[ ${BL_TYPE[$cur]-} == cons ]] || { echo 'BLisp compiler: improper call' >&2; return 1; }
    comp_expr "${BL_A[$cur]}" "$envvar" || return
    comp_temp; av=$COMP_REPLY; comp_emit "local $av=\$RET"; args+=("$av")
    cur=${BL_B[$cur]}
  done
  local call="bl_apply \"\$$ft\"" a
  for a in "${args[@]}"; do call+=" \"\$$a\""; done
  comp_emit "$call || return 1"
}

bl_compile_forms() {
  local outfile=$1 runtime_path=$2
  comp_reset
  local form
  for form in "${BL_FORMS[@]}"; do comp_expr "$form" ENV || return; done

  {
    printf '#!/usr/bin/env bash\n'
    tail -n +2 "$runtime_path"
    printf '\n# ---- generated BLisp closures ----\n'
    local i
    for ((i=1;i<=COMP_FN_SEQ;++i)); do printf '%s\n' "${COMP_BUF[fn$i]-}"; done
    printf '\n# ---- generated program ----\n'
    printf 'bl_runtime_init\n'
    printf 'BL_USER_ARGV=("$@")\n'
    printf 'ENV=$BL_GLOBAL_ENV\n'
    printf 'bl_compiled_main() {\n'
    printf '%s' "${COMP_BUF[main]}"
    printf '}\n'
    printf 'bl_compiled_main\n'
  } > "$outfile"
  chmod +x "$outfile"
}

bl_compile_source() {
  local src=$1 outfile=$2 runtime_path=$3
  bl_parse_all "$src" || return
  bl_compile_forms "$outfile" "$runtime_path"
}
