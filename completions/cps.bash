_cps_completions() {
  local cur prev commands
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="init create use list current delete save log rollback remote push pull diff edit doctor shell-init help version"

  case "$prev" in
    use|delete|rm|edit|log|diff)
      local profiles_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cps/profiles"
      if [[ -d "$profiles_dir" ]]; then
        local profiles
        profiles="$(ls -1 "$profiles_dir" 2>/dev/null)"
        COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
      fi
      return
      ;;
    create)
      COMPREPLY=($(compgen -W "--from" -- "$cur"))
      return
      ;;
    --from)
      local profiles_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cps/profiles"
      if [[ -d "$profiles_dir" ]]; then
        local profiles
        profiles="$(ls -1 "$profiles_dir" 2>/dev/null)"
        COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
      fi
      return
      ;;
    init)
      COMPREPLY=($(compgen -W "--key" -- "$cur"))
      return
      ;;
  esac

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
  fi
}

complete -F _cps_completions cps
