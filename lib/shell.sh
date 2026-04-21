#!/usr/bin/env bash
# lib/shell.sh — Shell integration output

set -euo pipefail

cmd_shell_init() {
  local data_dir="${CPS_DATA_DIR}"

  cat << SHELL_INIT
# cps shell integration — eval "\$(cps shell-init)"
export CPS_SHELL_INIT_SOURCED=1

_cps_activate() {
  local _active_file="${data_dir}/active"
  local _profiles_dir="${data_dir}/profiles"

  if [ -f "\$_active_file" ]; then
    local _name
    _name="\$(cat "\$_active_file")"
    if [ -n "\$_name" ] && [ -d "\${_profiles_dir}/\${_name}/claude" ]; then
      export CLAUDE_CONFIG_DIR="\${_profiles_dir}/\${_name}/claude"
    fi
  fi
}

cps() {
  command cps "\$@"
  local _exit_code=\$?

  if [ "\$1" = "use" ] && [ \$_exit_code -eq 0 ]; then
    _cps_activate
  fi

  return \$_exit_code
}

_cps_activate

_cps_bg_sync() {
  local _conf="${data_dir}/cps.conf"
  local _lock="${data_dir}/.sync.lock"

  [ -f "\$_conf" ] && grep -q '^sync_enabled=1' "\$_conf" 2>/dev/null || return 0
  [ -d "${data_dir}/.git" ] || return 0
  git -C "${data_dir}" remote get-url origin >/dev/null 2>&1 || return 0

  if [ -f "\$_lock" ]; then
    local _age=\$(( \$(date +%s) - \$(stat -c %Y "\$_lock" 2>/dev/null || echo 0) ))
    [ \$_age -lt 30 ] && return 0
    rm -f "\$_lock"
  fi

  touch "\$_lock"

  (
    local _branch
    _branch="\$(git -C "${data_dir}" branch --show-current 2>/dev/null || echo main)"
    git -C "${data_dir}" fetch -q origin "\$_branch" 2>/dev/null || { rm -f "\$_lock"; exit 0; }

    local _local _remote
    _local="\$(git -C "${data_dir}" rev-parse HEAD 2>/dev/null)"
    _remote="\$(git -C "${data_dir}" rev-parse "origin/\$_branch" 2>/dev/null || echo "\$_local")"

    if [ "\$_local" != "\$_remote" ]; then
      git -C "${data_dir}" rebase -q "origin/\$_branch" 2>/dev/null || {
        git -C "${data_dir}" rebase --abort 2>/dev/null
        git -C "${data_dir}" push -q --force-with-lease origin "\$_branch" 2>/dev/null
      }

      local _active_file="${data_dir}/active"
      if [ -f "\$_active_file" ]; then
        local _name
        _name="\$(cat "\$_active_file")"
        local _src="${data_dir}/profiles/\${_name}/claude.json"
        [ -f "\$_src" ] && cp -a "\$_src" "\$HOME/.claude.json" 2>/dev/null
      fi
    fi

    rm -f "\$_lock"
  ) >/dev/null 2>&1 &
}

_cps_bg_sync
SHELL_INIT
}
