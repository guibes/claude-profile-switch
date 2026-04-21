#!/usr/bin/env bash
# lib/crypto.sh — age encryption for credentials

set -euo pipefail

CPS_AGE_KEY_FILE="$CPS_DATA_DIR/age-key.txt"
CPS_AGE_RECIPIENT_FILE="$CPS_DATA_DIR/age-recipient.txt"

has_age() {
  command -v age &>/dev/null
}

require_age() {
  has_age || die "age not installed. Install: https://github.com/FiloSottile/age"
}

crypto_is_setup() {
  [[ -f "$CPS_AGE_KEY_FILE" ]] && [[ -f "$CPS_AGE_RECIPIENT_FILE" ]]
}

crypto_init() {
  if crypto_is_setup; then
    info "Encryption already configured."
    return
  fi

  require_age

  info "Generating age keypair..."
  age-keygen -o "$CPS_AGE_KEY_FILE" 2>/dev/null
  chmod 600 "$CPS_AGE_KEY_FILE"

  grep '^public key:' "$CPS_AGE_KEY_FILE" | sed 's/.*: //' > "$CPS_AGE_RECIPIENT_FILE"

  setup_git_filters
  setup_gitattributes

  ok "Encryption configured. Key: $CPS_AGE_KEY_FILE"
  warn "Back up your age key! Without it, encrypted credentials cannot be recovered."
}

crypto_init_with_key() {
  local key_path="$1"

  [[ -f "$key_path" ]] || die "Key file not found: $key_path"
  require_age

  cp "$key_path" "$CPS_AGE_KEY_FILE"
  chmod 600 "$CPS_AGE_KEY_FILE"

  grep '^public key:' "$CPS_AGE_KEY_FILE" | sed 's/.*: //' > "$CPS_AGE_RECIPIENT_FILE"

  setup_git_filters
  setup_gitattributes

  ok "Imported age key from $key_path"
}

setup_git_filters() {
  local recipient
  recipient="$(cat "$CPS_AGE_RECIPIENT_FILE")"

  git -C "$CPS_DATA_DIR" config filter.age-crypt.clean \
    "age -r '$recipient' -a"
  git -C "$CPS_DATA_DIR" config filter.age-crypt.smudge \
    "age -d -i '$CPS_AGE_KEY_FILE'"
  git -C "$CPS_DATA_DIR" config filter.age-crypt.required true
  git -C "$CPS_DATA_DIR" config diff.age-crypt.textconv \
    "age -d -i '$CPS_AGE_KEY_FILE'"
}

setup_gitattributes() {
  local ga="$CPS_DATA_DIR/.gitattributes"

  if [[ -f "$ga" ]] && grep -q 'age-crypt' "$ga" 2>/dev/null; then
    return
  fi

  echo '**/.credentials.json filter=age-crypt diff=age-crypt' >> "$ga"
}

encrypt_credentials_in_place() {
  if ! crypto_is_setup; then
    return
  fi

  local recipient
  recipient="$(cat "$CPS_AGE_RECIPIENT_FILE")"

  while IFS= read -r -d '' cred_file; do
    if head -1 "$cred_file" 2>/dev/null | grep -q '^-----BEGIN AGE ENCRYPTED FILE-----'; then
      continue
    fi

    local tmp="${cred_file}.tmp"
    if age -r "$recipient" -a -o "$tmp" "$cred_file" 2>/dev/null; then
      mv "$tmp" "$cred_file"
    else
      rm -f "$tmp"
      warn "Failed to encrypt: $cred_file"
    fi
  done < <(find "$CPS_PROFILES_DIR" -name '.credentials.json' -print0 2>/dev/null)
}

decrypt_credentials_in_place() {
  if ! crypto_is_setup; then
    return
  fi

  while IFS= read -r -d '' cred_file; do
    if ! head -1 "$cred_file" 2>/dev/null | grep -q '^-----BEGIN AGE ENCRYPTED FILE-----'; then
      continue
    fi

    local tmp="${cred_file}.tmp"
    if age -d -i "$CPS_AGE_KEY_FILE" -o "$tmp" "$cred_file" 2>/dev/null; then
      mv "$tmp" "$cred_file"
    else
      rm -f "$tmp"
      warn "Failed to decrypt: $cred_file"
    fi
  done < <(find "$CPS_PROFILES_DIR" -name '.credentials.json' -print0 2>/dev/null)
}
