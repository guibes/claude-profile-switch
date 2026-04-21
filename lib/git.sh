#!/usr/bin/env bash
# lib/git.sh — Git backup operations for profile storage

set -euo pipefail

git_init_repo() {
  if [[ -d "$CPS_DATA_DIR/.git" ]]; then
    return
  fi

  git -C "$CPS_DATA_DIR" init -q

  cat > "$CPS_DATA_DIR/.gitignore" << 'EOF'
age-key.txt
*.tmp
EOF

  git -C "$CPS_DATA_DIR" add -A
  git -C "$CPS_DATA_DIR" commit -q -m "Initialize CPS profile storage" --allow-empty
}

git_auto_commit() {
  local message="${1:-Auto-save}"

  if [[ ! -d "$CPS_DATA_DIR/.git" ]]; then
    return
  fi

  git -C "$CPS_DATA_DIR" add -A 2>/dev/null || true

  if ! git -C "$CPS_DATA_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$CPS_DATA_DIR" commit -q -m "$message" 2>/dev/null || true
  fi
}

cmd_save() {
  require_init
  local message="${1:-Update $(get_active_profile || echo 'profiles')}"
  git_auto_commit "$message"
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
  branch="$(git -C "$CPS_DATA_DIR" branch --show-current 2>/dev/null || echo "main")"
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
