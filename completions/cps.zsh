#compdef cps

_cps_profiles() {
  local profiles_dir="${XDG_DATA_HOME:-$HOME/.local/share}/cps/profiles"
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
    'sync:Auto-sync management (enable/disable/status)'
    'rename:Rename a profile'
    'export:Export profile as archive'
    'import:Import profile from archive'
    'clone:Clone profiles from remote'
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
        use|delete|rm|edit|log|diff|export|rename)
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
          sync_cmds=('enable:Enable auto-sync' 'disable:Disable auto-sync' 'status:Show sync state')
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
      esac
      ;;
  esac
}

_cps
