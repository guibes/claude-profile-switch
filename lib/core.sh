#!/usr/bin/env bash
# lib/core.sh — Profile CRUD and switching

set -euo pipefail

cmd_init() {
  local key_path="${1:-}"

  if [[ -d "$CPS_DATA_DIR" ]] && [[ -d "$CPS_PROFILES_DIR" ]]; then
    if [[ -n "$key_path" ]]; then
      crypto_init_with_key "$key_path"
      return
    fi
    warn "CPS already initialized at $CPS_DATA_DIR"
    return
  fi

  mkdir -p "$CPS_PROFILES_DIR"

  local default_profile="default"
  local profile_path
  profile_path="$(profile_dir "$default_profile")"

  info "Snapshotting current Claude config as '$default_profile' profile..."
  snapshot_claude_config "$profile_path"

  echo "$default_profile" > "$CPS_ACTIVE_FILE"

  git_init_repo

  if has_age; then
    crypto_init
  else
    warn "age not found. Credentials will be stored unencrypted in git."
    warn "Install age for encryption: https://github.com/FiloSottile/age"
  fi

  git_auto_commit "Create '$default_profile' profile from current config"

  ok "Initialized CPS at $CPS_DATA_DIR"
  ok "Created profile '$default_profile' from current config"
  echo ""
  info "Add to your shell rc file:"
  echo ""
  printf "  ${BOLD}eval \"\$(cps shell-init)\"${RESET}\n"
  echo ""
}

cmd_create() {
  require_init
  local name="${1:-}"
  local from="${2:-}"

  if [[ -z "$name" ]]; then
    die "Usage: cps create <name> [--from <profile>]"
  fi

  validate_profile_name "$name"

  if profile_exists "$name"; then
    die "Profile '$name' already exists."
  fi

  local target
  target="$(profile_dir "$name")"

  if [[ -n "$from" ]]; then
    profile_exists "$from" || die "Source profile '$from' not found."
    info "Creating '$name' from '$from'..."
    cp -a "$(profile_dir "$from")" "$target"
  else
    local active
    active="$(get_active_profile)"
    if [[ -n "$active" ]] && profile_exists "$active"; then
      save_current_claude_json
      info "Creating '$name' from active profile '$active'..."
      cp -a "$(profile_dir "$active")" "$target"
    else
      info "Creating '$name' from current Claude config..."
      snapshot_claude_config "$target"
    fi
  fi

  git_auto_commit "Create profile '$name'"
  git_auto_push
  ok "Created profile '$name'"
}

cmd_use() {
  require_init
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    die "Usage: cps use <name>"
  fi

  validate_profile_name "$name"
  profile_exists "$name" || die "Profile '$name' not found."

  local active
  active="$(get_active_profile)"

  if [[ "$active" == "$name" ]]; then
    info "Already on profile '$name'"
    return
  fi

  if [[ -n "$active" ]] && profile_exists "$active"; then
    save_current_claude_json
    git_auto_commit "Auto-save '$active' before switch"
  fi

  restore_claude_json "$name"
  echo "$name" > "$CPS_ACTIVE_FILE"

  git_auto_commit "Switch to profile '$name'"
  git_auto_push

  ok "Switched to profile '$name'"

  if [[ -z "${CPS_SHELL_INIT_SOURCED:-}" ]]; then
    echo ""
    warn "Shell integration not detected."
    info "CLAUDE_CONFIG_DIR won't update until you run:"
    printf "  ${BOLD}export CLAUDE_CONFIG_DIR=\"%s\"${RESET}\n" "$(profile_claude_dir "$name")"
    echo ""
    info "Or add to your rc file: eval \"\$(cps shell-init)\""
  fi
}

cmd_list() {
  require_init

  local active
  active="$(get_active_profile)"
  local profiles
  profiles="$(list_profiles)"

  if [[ -z "$profiles" ]]; then
    info "No profiles found."
    return
  fi

  while IFS= read -r name; do
    local claude_dir
    claude_dir="$(profile_claude_dir "$name")"
    local mod_date="-"
    if [[ -d "$claude_dir" ]]; then
      mod_date="$(date -r "$claude_dir" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "-")"
    fi

    if [[ "$name" == "$active" ]]; then
      printf "  ${GREEN}* %-20s${RESET} ${DIM}%s${RESET}\n" "$name" "$mod_date"
    else
      printf "    %-20s ${DIM}%s${RESET}\n" "$name" "$mod_date"
    fi
  done <<< "$profiles"
}

cmd_current() {
  require_init

  local active
  active="$(get_active_profile)"

  if [[ -z "$active" ]]; then
    info "No active profile."
    return 1
  fi

  echo "$active"
}

cmd_diff() {
  require_init
  local p1="${1:-}"
  local p2="${2:-}"

  if [[ -z "$p1" ]]; then
    p1="$(get_active_profile)"
    [[ -z "$p1" ]] && die "No active profile. Specify two profiles: cps diff <p1> <p2>"
  fi

  validate_profile_name "$p1"
  profile_exists "$p1" || die "Profile '$p1' not found."

  if [[ -z "$p2" ]]; then
    local profiles
    profiles="$(list_profiles)"
    while IFS= read -r name; do
      [[ "$name" == "$p1" ]] && continue
      echo ""
      printf "${BOLD}── %s vs %s ──${RESET}\n" "$p1" "$name"
      diff -rq "$(profile_claude_dir "$p1")" "$(profile_claude_dir "$name")" 2>/dev/null || true
    done <<< "$profiles"
    return
  fi

  validate_profile_name "$p2"
  profile_exists "$p2" || die "Profile '$p2' not found."

  diff -ru "$(profile_claude_dir "$p1")" "$(profile_claude_dir "$p2")" 2>/dev/null || true
}

cmd_edit() {
  require_init
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    name="$(get_active_profile)"
    [[ -z "$name" ]] && die "No active profile. Specify a profile: cps edit <name>"
  fi

  validate_profile_name "$name"
  profile_exists "$name" || die "Profile '$name' not found."

  local editor="${EDITOR:-${VISUAL:-vi}}"
  local target
  target="$(profile_claude_dir "$name")"

  info "Opening '$name' profile in $editor..."
  "$editor" "$target"
}

cmd_doctor() {
  require_init
  local issues=0

  printf "${BOLD}CPS Health Check${RESET}\n\n"

  if [[ -d "$CPS_DATA_DIR" ]]; then
    ok "Data directory: $CPS_DATA_DIR"
  else
    err "Data directory missing: $CPS_DATA_DIR"; ((issues++))
  fi

  if [[ -d "$CPS_DATA_DIR/.git" ]]; then
    ok "Git repo initialized"
  else
    err "Git repo not initialized"; ((issues++))
  fi

  local active
  active="$(get_active_profile)"
  if [[ -n "$active" ]]; then
    if profile_exists "$active"; then
      ok "Active profile: $active"
    else
      err "Active profile '$active' directory missing"; ((issues++))
    fi
  else
    warn "No active profile set"
  fi

  if has_age; then
    ok "age installed: $(age --version 2>&1 | head -1)"
    if crypto_is_setup; then
      ok "Encryption configured"
    else
      warn "age installed but encryption not configured. Run 'cps init' to set up."
    fi
  else
    warn "age not installed. Credentials stored unencrypted."
  fi

  local profile_count=0
  local profiles
  profiles="$(list_profiles)"
  if [[ -n "$profiles" ]]; then
    while IFS= read -r name; do
      profile_count=$((profile_count + 1))
      local cdir
      cdir="$(profile_claude_dir "$name")"
      if [[ ! -d "$cdir" ]]; then
        err "Profile '$name': claude/ directory missing"; ((issues++))
      fi
    done <<< "$profiles"
  fi
  ok "Profiles found: $profile_count"

  if [[ -n "${CPS_SHELL_INIT_SOURCED:-}" ]]; then
    ok "Shell integration active"
  else
    warn "Shell integration not detected. Add: eval \"\$(cps shell-init)\""
  fi

  if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    if [[ -d "$CLAUDE_CONFIG_DIR" ]]; then
      ok "CLAUDE_CONFIG_DIR: $CLAUDE_CONFIG_DIR"
    else
      err "CLAUDE_CONFIG_DIR points to missing dir: $CLAUDE_CONFIG_DIR"; ((issues++))
    fi
  else
    warn "CLAUDE_CONFIG_DIR not set"
  fi

  if sync_enabled; then
    ok "Auto-sync: enabled (device: $CPS_DEVICE_NAME)"
    if has_remote; then
      local sync_state
      sync_state="$(git_sync_status)"
      case "$sync_state" in
        synced)       ok "Sync status: $sync_state" ;;
        fetch-failed) err "Sync status: cannot reach remote"; ((issues++)) ;;
        *)            warn "Sync status: $sync_state" ;;
      esac
    else
      err "Auto-sync enabled but no remote configured"; ((issues++))
    fi
  else
    info "Auto-sync: disabled"
  fi

  echo ""
  if [[ $issues -eq 0 ]]; then
    ok "No issues found."
  else
    err "$issues issue(s) found."
  fi

  return $issues
}

cmd_delete() {
  require_init
  local name="${1:-}"

  if [[ -z "$name" ]]; then
    die "Usage: cps delete <name>"
  fi

  validate_profile_name "$name"
  profile_exists "$name" || die "Profile '$name' not found."

  local active
  active="$(get_active_profile)"

  if [[ "$name" == "$active" ]]; then
    die "Cannot delete active profile '$name'. Switch to another profile first."
  fi

  rm -rf "$(profile_dir "$name")"
  git_auto_commit "Delete profile '$name'"
  git_auto_push

  ok "Deleted profile '$name'"
}
