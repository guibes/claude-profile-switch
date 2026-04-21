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

# Key-level JSON merge: local keys win on conflict, remote-only keys added
json_key_merge() {
  local base="$1" local_f="$2" remote_f="$3" output="$4"

  python3 -c "
import json, sys

def load(p):
    try:
        with open(p) as f: return json.load(f)
    except: return {}

base, local, remote = load('$base'), load('$local_f'), load('$remote_f')
merged = dict(local)

for k, v in remote.items():
    if k not in local:
        merged[k] = v
    elif k not in base and k in local and k in remote and local[k] != remote[k]:
        merged[k] = local[k]

with open('$output', 'w') as f:
    json.dump(merged, f, indent=2)
" 2>/dev/null
}

git_smart_merge() {
  local branch="$1"
  local merge_base
  merge_base="$(git -C "$CPS_DATA_DIR" merge-base HEAD "origin/$branch" 2>/dev/null || echo "")"

  if [[ -n "$merge_base" ]] && command -v python3 &>/dev/null; then
    local json_files
    json_files="$(git -C "$CPS_DATA_DIR" diff --name-only "origin/$branch" -- '*.json' 2>/dev/null || true)"

    if [[ -n "$json_files" ]]; then
      local tmpdir
      tmpdir="$(mktemp -d)"

      while IFS= read -r jf; do
        local base_ver="$tmpdir/base.json"
        local remote_ver="$tmpdir/remote.json"
        local local_ver="$CPS_DATA_DIR/$jf"

        git -C "$CPS_DATA_DIR" show "$merge_base:$jf" > "$base_ver" 2>/dev/null || echo '{}' > "$base_ver"
        git -C "$CPS_DATA_DIR" show "origin/$branch:$jf" > "$remote_ver" 2>/dev/null || continue

        if [[ -f "$local_ver" ]]; then
          json_key_merge "$base_ver" "$local_ver" "$remote_ver" "$local_ver"
        fi
      done <<< "$json_files"

      rm -rf "$tmpdir"

      git -C "$CPS_DATA_DIR" add -A 2>/dev/null || true
      if ! git -C "$CPS_DATA_DIR" diff --cached --quiet 2>/dev/null; then
        git -C "$CPS_DATA_DIR" commit -q -m "Merge remote JSON changes [$CPS_DEVICE_NAME]" 2>/dev/null || true
      fi
    fi
  fi

  git -C "$CPS_DATA_DIR" rebase -q "origin/$branch" 2>/dev/null || {
    git -C "$CPS_DATA_DIR" rebase --abort 2>/dev/null || true
    git -C "$CPS_DATA_DIR" push -q --force-with-lease origin "$branch" 2>/dev/null || true
  }
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
      git_smart_merge "$branch"

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
      sync_unschedule_timer 2>/dev/null || true
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

      local sched
      sched="$(sync_schedule_status)"
      if [[ "$sched" != "none" ]]; then
        ok "Scheduled: $sched"
      fi
      ;;

    schedule)
      local interval="${2:-30m}"
      sync_schedule_timer "$interval"
      ;;

    unschedule)
      sync_unschedule_timer
      ;;

    *)
      die "Usage: cps sync [enable <url>|disable|status|schedule [interval]|unschedule]"
      ;;
  esac
}

sync_schedule_status() {
  if [[ "$(uname)" == "Darwin" ]]; then
    if [[ -f "$HOME/Library/LaunchAgents/com.cps.sync.plist" ]]; then
      local interval
      interval="$(defaults read "$HOME/Library/LaunchAgents/com.cps.sync" StartInterval 2>/dev/null || echo "?")"
      echo "every ${interval}s (launchd)"
    else
      echo "none"
    fi
  else
    if systemctl --user is-active cps-sync.timer &>/dev/null; then
      local interval
      interval="$(systemctl --user show cps-sync.timer -p Description --value 2>/dev/null | grep -oP '\d+\w+' || echo "?")"
      echo "every $interval (systemd)"
    else
      echo "none"
    fi
  fi
}

sync_schedule_timer() {
  local interval="$1"

  if [[ "$(uname)" == "Darwin" ]]; then
    sync_schedule_launchd "$interval"
  elif command -v systemctl &>/dev/null; then
    sync_schedule_systemd "$interval"
  else
    die "No supported scheduler found (need systemd or launchd)."
  fi
}

sync_unschedule_timer() {
  if [[ "$(uname)" == "Darwin" ]]; then
    local plist="$HOME/Library/LaunchAgents/com.cps.sync.plist"
    if [[ -f "$plist" ]]; then
      launchctl unload "$plist" 2>/dev/null || true
      rm -f "$plist"
      ok "Sync schedule removed (launchd)"
    else
      info "No sync schedule found."
    fi
  else
    if systemctl --user is-enabled cps-sync.timer &>/dev/null; then
      systemctl --user disable --now cps-sync.timer 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/cps-sync.service" "$HOME/.config/systemd/user/cps-sync.timer"
      systemctl --user daemon-reload 2>/dev/null || true
      ok "Sync schedule removed (systemd)"
    else
      info "No sync schedule found."
    fi
  fi
}

sync_schedule_systemd() {
  local interval="$1"
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"

  local cps_bin
  cps_bin="$(command -v cps 2>/dev/null || echo "$CPS_ROOT/bin/cps")"

  cat > "$unit_dir/cps-sync.service" << EOF
[Unit]
Description=CPS profile sync

[Service]
Type=oneshot
ExecStart=$cps_bin save "Scheduled sync" 
ExecStart=$cps_bin push
ExecStart=$cps_bin pull
EOF

  cat > "$unit_dir/cps-sync.timer" << EOF
[Unit]
Description=CPS sync every $interval

[Timer]
OnUnitActiveSec=$interval
OnBootSec=5m

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now cps-sync.timer

  ok "Sync scheduled every $interval (systemd)"
}

sync_schedule_launchd() {
  local interval="$1"
  local plist="$HOME/Library/LaunchAgents/com.cps.sync.plist"
  mkdir -p "$(dirname "$plist")"

  local seconds
  case "$interval" in
    *m) seconds=$(( ${interval%m} * 60 )) ;;
    *h) seconds=$(( ${interval%h} * 3600 )) ;;
    *s) seconds=${interval%s} ;;
    *)  seconds=$(( interval * 60 )) ;;
  esac

  local cps_bin
  cps_bin="$(command -v cps 2>/dev/null || echo "$CPS_ROOT/bin/cps")"

  cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cps.sync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>$cps_bin save "Scheduled sync" &amp;&amp; $cps_bin push &amp;&amp; $cps_bin pull</string>
  </array>
  <key>StartInterval</key>
  <integer>$seconds</integer>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist"

  ok "Sync scheduled every $interval (launchd)"
}
