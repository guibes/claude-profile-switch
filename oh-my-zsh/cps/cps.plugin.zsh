export CPS_SHELL_INIT_SOURCED=1

_cps_data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cps"

_cps_activate() {
  local _active_file="${_cps_data_dir}/active"
  local _profiles_dir="${_cps_data_dir}/profiles"

  if [[ -f "$_active_file" ]]; then
    local _name
    _name="$(cat "$_active_file")"
    if [[ -n "$_name" ]] && [[ -d "${_profiles_dir}/${_name}/claude" ]]; then
      export CLAUDE_CONFIG_DIR="${_profiles_dir}/${_name}/claude"
    fi
  fi
}

cps() {
  command cps "$@"
  local _exit_code=$?

  if [[ "$1" == "use" ]] && [[ $_exit_code -eq 0 ]]; then
    _cps_activate
  fi

  return $_exit_code
}

_cps_activate

# ── Aliases ────────────────────────────────────────────────────────────────────
alias cpsu='cps use'
alias cpsl='cps list'
alias cpsc='cps current'
alias cpss='cps save'

# ── Prompt segment (opt-in via CPS_PROMPT=1) ──────────────────────────────────
cps_prompt_info() {
  [[ "${CPS_PROMPT:-0}" != "1" ]] && return
  local _active_file="${_cps_data_dir}/active"
  if [[ -f "$_active_file" ]]; then
    local _name
    _name="$(cat "$_active_file")"
    [[ -n "$_name" ]] && echo "[cps:${_name}]"
  fi
}

# ── Completions ────────────────────────────────────────────────────────────────
_cps_profiles() {
  local profiles_dir="${_cps_data_dir}/profiles"
  if [[ -d "$profiles_dir" ]]; then
    local -a profiles
    profiles=(${profiles_dir}/*(N:t))
    _describe 'profile' profiles
  fi
}

_cps() {
  local -a commands
  commands=(
    'init:Initialize CPS and snapshot current config'
    'create:Create a new profile'
    'use:Switch to a profile'
    'list:List all profiles'
    'current:Print active profile name'
    'delete:Delete a profile'
    'save:Commit current state with message'
    'log:Show change history'
    'rollback:Restore to previous commit'
    'remote:Get/set git remote'
    'push:Push to remote'
    'pull:Pull from remote'
    'diff:Compare profiles'
    'edit:Open profile in editor'
    'doctor:Health check'
    'shell-init:Output shell integration code'
    'help:Show help'
    'version:Show version'
  )

  _arguments -C \
    '1:command:->command' \
    '*::arg:->args'

  case $state in
    command)
      _describe 'command' commands
      ;;
    args)
      case $words[1] in
        use|delete|rm|edit|log|diff)
          _cps_profiles
          ;;
        create)
          _arguments \
            '1:name:' \
            '--from[Copy from profile]:profile:_cps_profiles'
          ;;
        init)
          _arguments \
            '--key[Import age key]:key file:_files'
          ;;
        rollback)
          _message 'commit hash'
          ;;
        remote)
          _message 'git remote URL'
          ;;
        save)
          _message 'commit message'
          ;;
      esac
      ;;
  esac
}

compdef _cps cps
