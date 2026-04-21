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
  symlink_claude_dir "$default_profile"

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
  local fresh="${3:-}"
  local template="${4:-}"

  if [[ -z "$name" ]]; then
    die "Usage: cps create <name> [--from <profile> | --fresh | --template <url>]"
  fi

  validate_profile_name "$name"

  if profile_exists "$name"; then
    die "Profile '$name' already exists."
  fi

  local target
  target="$(profile_dir "$name")"

  if [[ -n "$template" ]]; then
    info "Creating '$name' from template..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    git clone -q --depth 1 "$template" "$tmpdir" || { rm -rf "$tmpdir"; die "Failed to clone template."; }
    rm -rf "$tmpdir/.git"
    mkdir -p "$target"
    if [[ -d "$tmpdir/claude" ]]; then
      cp -a "$tmpdir/." "$target/"
    else
      mkdir -p "$target/claude"
      cp -a "$tmpdir/." "$target/claude/"
    fi
    rm -rf "$tmpdir"
  elif [[ "$fresh" == "1" ]]; then
    info "Creating fresh profile '$name'..."
    create_fresh_profile "$target"
  elif [[ -n "$from" ]]; then
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
    run_profile_hooks "pre-switch" "$active"
    git_auto_commit "Auto-save '$active' before switch"
  fi

  restore_claude_json "$name"
  symlink_claude_dir "$name"
  echo "$name" > "$CPS_ACTIVE_FILE"

  local profile_desktop
  profile_desktop="$(profile_dir "$name")/desktop.json"
  local desktop_cfg="$HOME/.config/Claude/claude_desktop_config.json"
  if [[ -f "$profile_desktop" ]]; then
    mkdir -p "$(dirname "$desktop_cfg")"
    cp -a "$profile_desktop" "$desktop_cfg"
  fi

  git_auto_commit "Switch to profile '$name'"
  git_auto_push
  run_profile_hooks "post-switch" "$name"

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
    if [[ -z "$p1" ]]; then die "No active profile. Specify two profiles: cps diff <p1> <p2>"; fi
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
    if [[ -z "$name" ]]; then die "No active profile. Specify a profile: cps edit <name>"; fi
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

  if [[ -L "$CLAUDE_DIR" ]]; then
    local link_target
    link_target="$(readlink -f "$CLAUDE_DIR")"
    ok "~/.claude/ symlink: $link_target"
  elif [[ -d "$CLAUDE_DIR" ]]; then
    warn "~/.claude/ is a real directory (not symlinked). Run 'cps use <profile>' to fix."
    ((issues++))
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

cmd_status() {
  require_init

  local active
  active="$(get_active_profile)"
  if [[ -z "$active" ]]; then
    die "No active profile."
  fi

  local profile_cdir
  profile_cdir="$(profile_claude_dir "$active")"
  local profile_cjson
  profile_cjson="$(profile_claude_json "$active")"

  printf "${BOLD}Profile: %s${RESET}\n\n" "$active"

  local has_changes=0

  for item in "${PROFILE_CLAUDE_DIR_ITEMS[@]}"; do
    local live="$CLAUDE_DIR/$item"
    local stored="$profile_cdir/$item"

    if [[ -d "$live" ]] && [[ -d "$stored" ]]; then
      local diffs
      diffs="$(diff -rq "$stored" "$live" 2>/dev/null || true)"
      if [[ -n "$diffs" ]]; then
        printf "${YELLOW}~${RESET} %s/\n" "$item"
        echo "$diffs" | while IFS= read -r line; do
          printf "    %s\n" "$line"
        done
        has_changes=1
      fi
    elif [[ -f "$live" ]] && [[ -f "$stored" ]]; then
      if ! diff -q "$stored" "$live" &>/dev/null; then
        printf "${YELLOW}~${RESET} %s\n" "$item"
        has_changes=1
      fi
    elif [[ -e "$live" ]] && [[ ! -e "$stored" ]]; then
      printf "${GREEN}+${RESET} %s (new, not in profile)\n" "$item"
      has_changes=1
    elif [[ ! -e "$live" ]] && [[ -e "$stored" ]]; then
      printf "${RED}-${RESET} %s (in profile, missing live)\n" "$item"
      has_changes=1
    fi
  done

  if [[ -f "$CLAUDE_JSON" ]] && [[ -f "$profile_cjson" ]]; then
    if ! diff -q "$profile_cjson" "$CLAUDE_JSON" &>/dev/null; then
      printf "${YELLOW}~${RESET} claude.json\n"
      has_changes=1
    fi
  fi

  local desktop_cfg="$HOME/.config/Claude/claude_desktop_config.json"
  local profile_desktop
  profile_desktop="$(profile_dir "$active")/desktop.json"
  if [[ -f "$desktop_cfg" ]] && [[ -f "$profile_desktop" ]]; then
    if ! diff -q "$profile_desktop" "$desktop_cfg" &>/dev/null; then
      printf "${YELLOW}~${RESET} desktop.json (Claude Desktop)\n"
      has_changes=1
    fi
  elif [[ -f "$desktop_cfg" ]] && [[ ! -f "$profile_desktop" ]]; then
    printf "${DIM}?${RESET} desktop.json (Claude Desktop not tracked — use 'cps snapshot --desktop')\n"
  fi

  if [[ $has_changes -eq 0 ]]; then
    ok "Clean — profile matches live state."
  else
    echo ""
    info "Run 'cps snapshot' to save live changes to profile."
  fi
}

cmd_snapshot() {
  require_init
  local include_desktop=0

  for arg in "$@"; do
    case "$arg" in
      --desktop) include_desktop=1 ;;
      *) die "Unknown option: $arg" ;;
    esac
  done

  local active
  active="$(get_active_profile)"
  if [[ -z "$active" ]]; then
    die "No active profile."
  fi

  save_current_claude_json

  local profile_cdir
  profile_cdir="$(profile_claude_dir "$active")"

  local live_resolved
  live_resolved="$(readlink -f "$CLAUDE_DIR" 2>/dev/null || echo "$CLAUDE_DIR")"
  local stored_resolved
  stored_resolved="$(readlink -f "$profile_cdir" 2>/dev/null || echo "$profile_cdir")"

  if [[ "$live_resolved" != "$stored_resolved" ]]; then
    for item in "${PROFILE_CLAUDE_DIR_ITEMS[@]}"; do
      local live="$CLAUDE_DIR/$item"
      local stored="$profile_cdir/$item"
      if [[ -e "$live" ]]; then
        safe_copy "$live" "$stored"
      fi
    done
  fi

  if [[ "$include_desktop" == "1" ]]; then
    local desktop_cfg="$HOME/.config/Claude/claude_desktop_config.json"
    if [[ -f "$desktop_cfg" ]]; then
      cp -a "$desktop_cfg" "$(profile_dir "$active")/desktop.json"
      ok "Saved Claude Desktop config"
    else
      warn "Claude Desktop config not found at $desktop_cfg"
    fi
  fi

  git_auto_commit "Snapshot profile '$active'"
  git_auto_push

  ok "Snapshot saved for '$active'"
}

cmd_desktop() {
  require_init
  local subcmd="${1:-status}"

  local desktop_cfg="$HOME/.config/Claude/claude_desktop_config.json"

  local active
  active="$(get_active_profile)"
  if [[ -z "$active" ]]; then
    die "No active profile."
  fi

  local profile_desktop
  profile_desktop="$(profile_dir "$active")/desktop.json"

  case "$subcmd" in
    save)
      if [[ ! -f "$desktop_cfg" ]]; then
        die "Claude Desktop config not found at $desktop_cfg"
      fi
      cp -a "$desktop_cfg" "$profile_desktop"
      git_auto_commit "Save Claude Desktop config for '$active'"
      git_auto_push
      ok "Saved Claude Desktop config to profile '$active'"
      ;;

    restore)
      if [[ ! -f "$profile_desktop" ]]; then
        die "No desktop config stored for profile '$active'. Run 'cps desktop save' first."
      fi
      mkdir -p "$(dirname "$desktop_cfg")"
      cp -a "$profile_desktop" "$desktop_cfg"
      ok "Restored Claude Desktop config from profile '$active'"
      ;;

    status)
      if [[ ! -f "$desktop_cfg" ]]; then
        info "Claude Desktop: not installed"
        return
      fi

      if [[ ! -f "$profile_desktop" ]]; then
        info "Claude Desktop: config exists but not tracked"
        info "Run 'cps desktop save' to add to profile"
        return
      fi

      if diff -q "$profile_desktop" "$desktop_cfg" &>/dev/null; then
        ok "Claude Desktop: synced with profile"
      else
        warn "Claude Desktop: config differs from profile"
        info "Run 'cps desktop save' to update, or 'cps desktop restore' to revert"
      fi
      ;;

    *)
      die "Usage: cps desktop [save|restore|status]"
      ;;
  esac
}

cmd_export() {
  require_init
  local name="${1:-}"
  local dest="${2:-}"

  if [[ -z "$name" ]]; then
    die "Usage: cps export <name> [path]"
  fi

  validate_profile_name "$name"
  profile_exists "$name" || die "Profile '$name' not found."

  if [[ -z "$dest" ]]; then
    dest="./${name}.cps.tar.gz"
  fi

  local pdir
  pdir="$(profile_dir "$name")"

  tar -czf "$dest" -C "$CPS_PROFILES_DIR" "$name"

  ok "Exported '$name' to $dest"
}

cmd_import() {
  require_init
  local archive="${1:-}"
  local name="${2:-}"

  if [[ -z "$archive" ]]; then
    die "Usage: cps import <archive> [name]"
  fi

  [[ -f "$archive" ]] || die "File not found: $archive"

  local archive_root
  archive_root="$(tar -tzf "$archive" 2>/dev/null | head -1 | cut -d'/' -f1 || true)"
  if [[ -z "$archive_root" ]]; then
    die "Cannot read archive."
  fi

  if [[ -z "$name" ]]; then
    name="$archive_root"
  fi

  validate_profile_name "$name"

  if profile_exists "$name"; then
    die "Profile '$name' already exists. Delete it first or specify a different name."
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"

  tar -xzf "$archive" -C "$tmpdir" || { rm -rf "$tmpdir"; die "Failed to extract archive."; }

  if [[ ! -d "$tmpdir/$archive_root" ]]; then
    rm -rf "$tmpdir"
    die "Archive doesn't contain expected directory '$archive_root'."
  fi

  mv "$tmpdir/$archive_root" "$CPS_PROFILES_DIR/$name"
  rm -rf "$tmpdir"

  git_auto_commit "Import profile '$name'"
  git_auto_push

  ok "Imported profile '$name'"
}

cmd_rename() {
  require_init
  local old="${1:-}"
  local new="${2:-}"

  if [[ -z "$old" ]] || [[ -z "$new" ]]; then
    die "Usage: cps rename <old> <new>"
  fi

  validate_profile_name "$old"
  validate_profile_name "$new"
  profile_exists "$old" || die "Profile '$old' not found."

  if profile_exists "$new"; then
    die "Profile '$new' already exists."
  fi

  mv "$(profile_dir "$old")" "$(profile_dir "$new")"

  local active
  active="$(get_active_profile)"
  if [[ "$old" == "$active" ]]; then
    echo "$new" > "$CPS_ACTIVE_FILE"
  fi

  git_auto_commit "Rename profile '$old' to '$new'"
  git_auto_push

  ok "Renamed '$old' to '$new'"
}

cmd_clone() {
  local url="${1:-}"

  if [[ -z "$url" ]]; then
    die "Usage: cps clone <remote-url>"
  fi

  if [[ -d "$CPS_DATA_DIR" ]] && [[ -d "$CPS_PROFILES_DIR" ]]; then
    local existing
    existing="$(list_profiles | wc -l)"
    if [[ "$existing" -gt 0 ]]; then
      die "CPS already has profiles. Use 'cps pull' to sync, or remove $CPS_DATA_DIR first."
    fi
  fi

  info "Cloning profiles from remote..."
  rm -rf "$CPS_DATA_DIR"
  git clone -q "$url" "$CPS_DATA_DIR" || die "Clone failed."

  local active
  active="$(get_active_profile)"
  if [[ -n "$active" ]] && profile_exists "$active"; then
    restore_claude_json "$active"
    symlink_claude_dir "$active"
    ok "Cloned and activated profile '$active'"
  else
    local first
    first="$(list_profiles | head -1 || true)"
    if [[ -n "$first" ]]; then
      echo "$first" > "$CPS_ACTIVE_FILE"
      restore_claude_json "$first"
      symlink_claude_dir "$first"
      ok "Cloned profiles. Activated '$first'"
    else
      ok "Cloned. No profiles found in remote."
    fi
  fi

  info "Run: eval \"\$(cps shell-init)\" or restart your shell"
}

run_profile_hooks() {
  local hook_name="$1"
  local profile_name="$2"
  local hooks_dir
  hooks_dir="$(profile_claude_dir "$profile_name")/hooks"

  if [[ ! -d "$hooks_dir" ]]; then
    return
  fi

  local hook_file="$hooks_dir/$hook_name"
  if [[ -x "$hook_file" ]]; then
    info "Running $hook_name hook..."
    CPS_PROFILE="$profile_name" CPS_HOOK="$hook_name" "$hook_file" || warn "Hook $hook_name exited with error"
  fi
}

cmd_upgrade() {
  if [[ ! -d "$CPS_ROOT/.git" ]]; then
    die "CPS was not installed via git clone. Cannot auto-upgrade."
  fi

  info "Checking for updates..."

  local current="$CPS_VERSION"
  local latest
  latest="$(git -C "$CPS_ROOT" ls-remote --tags origin 2>/dev/null \
    | grep -o 'refs/tags/v[0-9]*\.[0-9]*\.[0-9]*$' \
    | sed 's|refs/tags/||' \
    | sort -V \
    | tail -1 || true)"

  if [[ -z "$latest" ]]; then
    die "Cannot fetch latest version. Check network and remote."
  fi

  if [[ "v$current" == "$latest" ]]; then
    ok "Already on latest version ($current)"
    return
  fi

  info "Upgrading: v$current → $latest"

  git -C "$CPS_ROOT" fetch -q --tags origin || die "Fetch failed."
  git -C "$CPS_ROOT" checkout -q "$latest" || die "Checkout failed."

  ok "Upgraded to $latest"
  info "Run 'cps version' to confirm."
}
