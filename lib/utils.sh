#!/usr/bin/env bash
# cps - Claude Profile Switch
# lib/utils.sh — Colors, logging, path constants, helpers

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────
CPS_DATA_DIR="${CPS_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cps}"
CPS_PROFILES_DIR="$CPS_DATA_DIR/profiles"
CPS_ACTIVE_FILE="$CPS_DATA_DIR/active"
CPS_CONF_FILE="$CPS_DATA_DIR/cps.conf"
CPS_SYNC_LOCK="$CPS_DATA_DIR/.sync.lock"
CPS_DEVICE_NAME="${CPS_DEVICE_NAME:-$(hostname -s 2>/dev/null || echo 'unknown')}"

CLAUDE_DIR="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"

# Files/dirs inside ~/.claude/ that constitute a profile
PROFILE_CLAUDE_DIR_ITEMS=(
  ".credentials.json"
  "config.json"
  "settings.json"
  "CLAUDE.md"
  "skills"
  "commands"
  "agents"
)

# ── Colors ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ── Logging ────────────────────────────────────────────────────────────────────
info()  { printf "${BLUE}▸${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${RESET} %s\n" "$*" >&2; }
err()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; }
die()   { err "$@"; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────────

get_active_profile() {
  if [[ -f "$CPS_ACTIVE_FILE" ]]; then
    cat "$CPS_ACTIVE_FILE"
  fi
}

# ── Config (key=value in cps.conf) ────────────────────────────────────────────

conf_get() {
  local key="$1" default="${2:-}"
  if [[ -f "$CPS_CONF_FILE" ]]; then
    local val
    val="$(grep "^${key}=" "$CPS_CONF_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-)"
    [[ -n "$val" ]] && echo "$val" || echo "$default"
  else
    echo "$default"
  fi
}

conf_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$CPS_CONF_FILE")"
  if [[ -f "$CPS_CONF_FILE" ]] && grep -q "^${key}=" "$CPS_CONF_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CPS_CONF_FILE"
  else
    echo "${key}=${val}" >> "$CPS_CONF_FILE"
  fi
}

sync_enabled() {
  [[ "$(conf_get sync_enabled 0)" == "1" ]]
}


# Check if a profile exists
profile_exists() {
  local name="$1"
  [[ -d "$CPS_PROFILES_DIR/$name" ]]
}

# Get profile directory path
profile_dir() {
  local name="$1"
  echo "$CPS_PROFILES_DIR/$name"
}

# Get the claude/ subdirectory inside a profile (what CLAUDE_CONFIG_DIR points to)
profile_claude_dir() {
  local name="$1"
  echo "$CPS_PROFILES_DIR/$name/claude"
}

# Get the claude.json path inside a profile
profile_claude_json() {
  local name="$1"
  echo "$CPS_PROFILES_DIR/$name/claude.json"
}

# Validate profile name (alphanumeric, hyphens, underscores)
validate_profile_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Invalid profile name '$name'. Use only letters, numbers, hyphens, underscores."
  fi
  if [[ ${#name} -gt 64 ]]; then
    die "Profile name too long (max 64 chars)."
  fi
}

# List all profile names
list_profiles() {
  if [[ ! -d "$CPS_PROFILES_DIR" ]]; then
    return
  fi
  for dir in "$CPS_PROFILES_DIR"/*/; do
    [[ -d "$dir" ]] && basename "$dir"
  done
}

# Ensure CPS is initialized
require_init() {
  if [[ ! -d "$CPS_DATA_DIR" ]] || [[ ! -d "$CPS_PROFILES_DIR" ]]; then
    die "CPS not initialized. Run 'cps init' first."
  fi
}

# Copy a file or directory, creating parent dirs as needed
safe_copy() {
  local src="$1" dst="$2"
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    cp -a "$src/." "$dst/" 2>/dev/null || true
  elif [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

# Snapshot current Claude config into a profile directory
snapshot_claude_config() {
  local target_dir="$1"
  local claude_subdir="$target_dir/claude"

  mkdir -p "$claude_subdir"

  for item in "${PROFILE_CLAUDE_DIR_ITEMS[@]}"; do
    local src="$CLAUDE_DIR/$item"
    local dst="$claude_subdir/$item"
    if [[ -e "$src" ]]; then
      safe_copy "$src" "$dst"
    fi
  done

  if [[ -f "$CLAUDE_JSON" ]]; then
    cp -a "$CLAUDE_JSON" "$target_dir/claude.json"
  fi
}

# Restore ~/.claude.json from a profile
restore_claude_json() {
  local profile_name="$1"
  local src
  src="$(profile_claude_json "$profile_name")"

  if [[ -f "$src" ]]; then
    cp -a "$src" "$CLAUDE_JSON"
  fi
}

# Save current ~/.claude.json back to active profile
save_current_claude_json() {
  local active
  active="$(get_active_profile)"
  if [[ -n "$active" ]] && profile_exists "$active"; then
    if [[ -f "$CLAUDE_JSON" ]]; then
      cp -a "$CLAUDE_JSON" "$(profile_claude_json "$active")"
    fi
  fi
}
