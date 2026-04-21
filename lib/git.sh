#!/usr/bin/env bash
# lib/git.sh — Git backup + sync operations

set -euo pipefail

has_remote() {
  git -C "$CPS_DATA_DIR" remote get-url origin &>/dev/null
}

git_branch() {
  git -C "$CPS_DATA_DIR" branch --show-current 2>/dev/null || echo "main"
}

git_init_repo() {
  if [[ -d "$CPS_DATA_DIR/.git" ]]; then
    return
  fi

  git -C "$CPS_DATA_DIR" init -q

  cat > "$CPS_DATA_DIR/.gitignore" << 'EOF'
age-key.txt
*.tmp
.sync.lock
EOF

  git -C "$CPS_DATA_DIR" add -A
  git -C "$CPS_DATA_DIR" commit -q -m "Initialize CPS profile storage [$CPS_DEVICE_NAME]" --allow-empty
}

git_auto_commit() {
  local message="${1:-Auto-save}"

  if [[ ! -d "$CPS_DATA_DIR/.git" ]]; then
    return
  fi

  git -C "$CPS_DATA_DIR" add -A 2>/dev/null || true

  if ! git -C "$CPS_DATA_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$CPS_DATA_DIR" commit -q -m "$message [$CPS_DEVICE_NAME]" 2>/dev/null || true
  fi
}

git_auto_push() {
  if ! sync_enabled || ! has_remote; then
    return
  fi

  local branch
  branch="$(git_branch)"
  git -C "$CPS_DATA_DIR" push -q origin "$branch" 2>/dev/null || true
}

# Non-blocking background pull — safe for shell startup
git_bg_pull() {
  if ! sync_enabled || ! has_remote; then
    return
  fi

  if [[ -f "$CPS_SYNC_LOCK" ]]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -c %Y "$CPS_SYNC_LOCK" 2>/dev/null || echo 0) ))
    if [[ $lock_age -lt 30 ]]; then
      return
    fi
    rm -f "$CPS_SYNC_LOCK"
  fi

  touch "$CPS_SYNC_LOCK"

  (
    local branch
    branch="$(git_branch)"

    git -C "$CPS_DATA_DIR" fetch -q origin "$branch" 2>/dev/null || { rm -f "$CPS_SYNC_LOCK"; exit 0; }

    local local_head remote_head
    local_head="$(git -C "$CPS_DATA_DIR" rev-parse HEAD 2>/dev/null)"
    remote_head="$(git -C "$CPS_DATA_DIR" rev-parse "origin/$branch" 2>/dev/null || echo "$local_head")"

    if [[ "$local_head" != "$remote_head" ]]; then
      git -C "$CPS_DATA_DIR" rebase -q "origin/$branch" 2>/dev/null || {
        git -C "$CPS_DATA_DIR" rebase --abort 2>/dev/null || true
        git -C "$CPS_DATA_DIR" push -q --force-with-lease origin "$branch" 2>/dev/null || true
      }

      local active
      active=""
      [[ -f "$CPS_ACTIVE_FILE" ]] && active="$(cat "$CPS_ACTIVE_FILE")"
      if [[ -n "$active" ]] && [[ -d "$CPS_PROFILES_DIR/$active" ]]; then
        local src="$CPS_PROFILES_DIR/$active/claude.json"
        [[ -f "$src" ]] && cp -a "$src" "$HOME/.claude.json" 2>/dev/null || true
      fi
    fi

    rm -f "$CPS_SYNC_LOCK"
  ) &
  disown 2>/dev/null || true
}

git_sync_status() {
  if ! has_remote; then
    echo "no-remote"
    return
  fi

  local branch
  branch="$(git_branch)"

  git -C "$CPS_DATA_DIR" fetch -q origin "$branch" 2>/dev/null || { echo "fetch-failed"; return; }

  local local_head remote_head
  local_head="$(git -C "$CPS_DATA_DIR" rev-parse HEAD 2>/dev/null)"
  remote_head="$(git -C "$CPS_DATA_DIR" rev-parse "origin/$branch" 2>/dev/null || echo "")"

  if [[ -z "$remote_head" ]]; then
    echo "no-upstream"
  elif [[ "$local_head" == "$remote_head" ]]; then
    echo "synced"
  else
    local ahead behind
    ahead="$(git -C "$CPS_DATA_DIR" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
    behind="$(git -C "$CPS_DATA_DIR" rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)"

    if [[ "$behind" -gt 0 ]] && [[ "$ahead" -gt 0 ]]; then
      echo "diverged (${ahead} ahead, ${behind} behind)"
    elif [[ "$ahead" -gt 0 ]]; then
      echo "ahead by ${ahead}"
    else
      echo "behind by ${behind}"
    fi
  fi
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_save() {
  require_init
  local message="${1:-Update $(get_active_profile || echo 'profiles')}"
  git_auto_commit "$message"
  git_auto_push
  ok "Saved: $message"
}

cmd_log() {
  require_init
  local profile="${1:-}"

  if [[ -n "$profile" ]]; then
    validate_profile_name "$profile"
    profile_exists "$profile" || die "Profile '$profile' not found."
    git -C "$CPS_DATA_DIR" log --oneline --no-decorate -- "profiles/$profile"
  else
    git -C "$CPS_DATA_DIR" log --oneline --no-decorate
  fi
}

cmd_rollback() {
  require_init
  local commit="${1:-}"

  if [[ -z "$commit" ]]; then
    die "Usage: cps rollback <commit-hash>"
  fi

  local active
  active="$(get_active_profile)"

  git -C "$CPS_DATA_DIR" checkout "$commit" -- . 2>/dev/null \
    || die "Failed to rollback to commit '$commit'."

  git_auto_commit "Rollback to $commit"

  if [[ -n "$active" ]] && profile_exists "$active"; then
    restore_claude_json "$active"
  fi

  git_auto_push
  ok "Rolled back to $commit"
}

cmd_remote() {
  require_init
  local url="${1:-}"

  if [[ -z "$url" ]]; then
    local current
    current="$(git -C "$CPS_DATA_DIR" remote get-url origin 2>/dev/null || echo "none")"
    info "Current remote: $current"
    return
  fi

  if git -C "$CPS_DATA_DIR" remote get-url origin &>/dev/null; then
    git -C "$CPS_DATA_DIR" remote set-url origin "$url"
  else
    git -C "$CPS_DATA_DIR" remote add origin "$url"
  fi
  ok "Remote set to $url"
}

cmd_push() {
  require_init
  git_auto_commit "Pre-push save"

  local branch
  branch="$(git_branch)"
  git -C "$CPS_DATA_DIR" push -u origin "$branch" || die "Push failed. Set remote with 'cps remote <url>'."
  ok "Pushed to remote"
}

cmd_pull() {
  require_init
  git -C "$CPS_DATA_DIR" pull --rebase || die "Pull failed."

  local active
  active="$(get_active_profile)"
  if [[ -n "$active" ]] && profile_exists "$active"; then
    restore_claude_json "$active"
  fi

  ok "Pulled from remote"
}

cmd_sync() {
  require_init
  local subcmd="${1:-status}"

  case "$subcmd" in
    enable)
      local url="${2:-}"
      if [[ -z "$url" ]] && ! has_remote; then
        die "Usage: cps sync enable <remote-url>"
      fi

      if [[ -n "$url" ]]; then
        cmd_remote "$url"
      fi

      conf_set sync_enabled 1
      conf_set device_name "$CPS_DEVICE_NAME"

      git_auto_commit "Enable sync from $CPS_DEVICE_NAME"

      local branch
      branch="$(git_branch)"
      git -C "$CPS_DATA_DIR" push -u origin "$branch" 2>/dev/null \
        || die "Push failed. Check remote URL and permissions."

      ok "Sync enabled. Device: $CPS_DEVICE_NAME"
      info "Profiles will auto-push on changes and auto-pull on shell start."
      ;;

    disable)
      conf_set sync_enabled 0
      git_auto_commit "Disable sync from $CPS_DEVICE_NAME"
      ok "Sync disabled. Use 'cps push/pull' for manual sync."
      ;;

    status)
      if sync_enabled; then
        ok "Sync: enabled"
      else
        info "Sync: disabled"
      fi

      info "Device: $CPS_DEVICE_NAME"

      if has_remote; then
        local remote_url
        remote_url="$(git -C "$CPS_DATA_DIR" remote get-url origin 2>/dev/null)"
        info "Remote: $remote_url"

        local status
        status="$(git_sync_status)"
        case "$status" in
          synced)        ok "Status: $status" ;;
          no-upstream)   warn "Status: $status" ;;
          fetch-failed)  err "Status: cannot reach remote" ;;
          *)             warn "Status: $status" ;;
        esac
      else
        info "Remote: none"
      fi

      local last_commit
      last_commit="$(git -C "$CPS_DATA_DIR" log -1 --format='%ar by %an' 2>/dev/null || echo "never")"
      info "Last change: $last_commit"
      ;;

    *)
      die "Usage: cps sync [enable <url>|disable|status]"
      ;;
  esac
}
