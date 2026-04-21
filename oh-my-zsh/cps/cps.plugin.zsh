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

_cps_bg_sync() {
  local _conf="${_cps_data_dir}/cps.conf"
  local _lock="${_cps_data_dir}/.sync.lock"

  [[ -f "$_conf" ]] && grep -q '^sync_enabled=1' "$_conf" 2>/dev/null || return 0

  [[ -d "${_cps_data_dir}/.git" ]] || return 0
  git -C "$_cps_data_dir" remote get-url origin &>/dev/null || return 0

  if [[ -f "$_lock" ]]; then
    local _age=$(( $(date +%s) - $(stat -c %Y "$_lock" 2>/dev/null || echo 0) ))
    [[ $_age -lt 30 ]] && return 0
    rm -f "$_lock"
  fi

  touch "$_lock"

  (
    local _branch
    _branch="$(git -C "$_cps_data_dir" branch --show-current 2>/dev/null || echo main)"

    git -C "$_cps_data_dir" fetch -q origin "$_branch" 2>/dev/null || { rm -f "$_lock"; exit 0; }

    local _local _remote
    _local="$(git -C "$_cps_data_dir" rev-parse HEAD 2>/dev/null)"
    _remote="$(git -C "$_cps_data_dir" rev-parse "origin/$_branch" 2>/dev/null || echo "$_local")"

    if [[ "$_local" != "$_remote" ]]; then
      git -C "$_cps_data_dir" rebase -q "origin/$_branch" 2>/dev/null || {
        git -C "$_cps_data_dir" rebase --abort 2>/dev/null
        git -C "$_cps_data_dir" push -q --force-with-lease origin "$_branch" 2>/dev/null
      }

      local _active_file="${_cps_data_dir}/active"
      if [[ -f "$_active_file" ]]; then
        local _name
        _name="$(cat "$_active_file")"
        local _src="${_cps_data_dir}/profiles/${_name}/claude.json"
        [[ -f "$_src" ]] && cp -a "$_src" "$HOME/.claude.json" 2>/dev/null
      fi
    fi

    rm -f "$_lock"
  ) &>/dev/null &
  disown 2>/dev/null
}

_cps_bg_sync

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
    'pick:Interactive profile picker'
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
    'sync:Auto-sync management (enable/disable/status)'
    'rename:Rename a profile'
    'export:Export profile as archive'
    'import:Import profile from archive'
    'clone:Clone profiles from remote'
    'link:Symlink item from another profile'
    'unlink:Remove symlink and restore original'
    'lock:Prevent modifications to a profile'
    'unlock:Remove lock from a profile'
    'tag:Add tag to profile'
    'untag:Remove tag from profile'
    'tags:List all tags'
    'audit:Query audit log'
    'status:Show diff between profile and live state'
    'snapshot:Save live config back to profile'
    'desktop:Manage Claude Desktop config'
    'diff:Compare profiles'
    'edit:Open profile in editor'
    'doctor:Health check'
    'upgrade:Self-update to latest version'
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
        use|delete|rm|edit|log|diff|export|rename|lock|unlock)
          _cps_profiles
          ;;
        create)
          _arguments \
            '1:name:' \
            '--from[Copy from profile]:profile:_cps_profiles' \
            '--fresh[Create clean profile with no inherited config]' \
            '--template[Create from git template]:url:'
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
        sync)
          local -a sync_cmds
          sync_cmds=('enable:Enable auto-sync' 'disable:Disable auto-sync' 'status:Show sync state' 'schedule:Install periodic sync timer' 'unschedule:Remove sync timer')
          _describe 'sync command' sync_cmds
          ;;
        desktop)
          local -a desktop_cmds
          desktop_cmds=('save:Save desktop config' 'restore:Restore desktop config' 'status:Check sync')
          _describe 'desktop command' desktop_cmds
          ;;
        snapshot)
          _arguments '--desktop[Include Claude Desktop config]'
          ;;
        link)
          local -a items
          items=('skills' 'commands' 'agents' 'hooks' 'settings.json' 'config.json' 'CLAUDE.md')
          _arguments '1:item:($items)' '2:source profile:_cps_profiles'
          ;;
        unlink)
          local -a items
          items=('skills' 'commands' 'agents' 'hooks' 'settings.json' 'config.json' 'CLAUDE.md')
          _arguments '1:item:($items)'
          ;;
        tag|untag)
          _arguments '1:profile:_cps_profiles' '2:tag:'
          ;;
        list|ls)
          _arguments '--tag[Filter by tag]:tag:'
          ;;
        audit)
          _arguments '--action[Filter by action]:action:' '--profile[Filter by profile]:profile:_cps_profiles' '--since[Filter by time]:period:' '--limit[Max results]:count:'
          ;;
      esac
      ;;
  esac
}

compdef _cps cps
