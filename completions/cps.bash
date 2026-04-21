_cps_completions() {
  local cur prev commands
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  commands="pick init create use list current delete rename export import clone link unlink lock unlock tag untag tags status snapshot desktop audit save log rollback remote push pull sync diff edit doctor upgrade shell-init help version"

  case "$prev" in
    use|delete|rm|edit|log|diff|export|rename|lock|unlock)
      local profiles_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cps/profiles"
      if [[ -d "$profiles_dir" ]]; then
        local profiles
        profiles="$(ls -1 "$profiles_dir" 2>/dev/null)"
        COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
      fi
      return
      ;;
    create)
      COMPREPLY=($(compgen -W "--from --fresh" -- "$cur"))
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
    tag|untag)
      local profiles_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cps/profiles"
      if [[ -d "$profiles_dir" ]]; then
        local profiles
        profiles="$(ls -1 "$profiles_dir" 2>/dev/null)"
        COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
      fi
      return
      ;;
    list|ls)
      COMPREPLY=($(compgen -W "--tag" -- "$cur"))
      return
      ;;
    audit)
      COMPREPLY=($(compgen -W "--action --profile --since --limit" -- "$cur"))
      return
      ;;
    sync)
      COMPREPLY=($(compgen -W "enable disable status schedule unschedule" -- "$cur"))
      return
      ;;
    desktop)
      COMPREPLY=($(compgen -W "save restore status" -- "$cur"))
      return
      ;;
    snapshot)
      COMPREPLY=($(compgen -W "--desktop" -- "$cur"))
      return
      ;;
    link|unlink)
      COMPREPLY=($(compgen -W "skills commands agents hooks settings.json config.json CLAUDE.md" -- "$cur"))
      return
      ;;
  esac

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
  fi
}

complete -F _cps_completions cps
