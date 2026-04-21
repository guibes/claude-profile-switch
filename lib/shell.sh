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
SHELL_INIT
}
