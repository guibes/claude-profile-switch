#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/guibes/claude-profile-switch.git"
INSTALL_DIR="${CPS_INSTALL_DIR:-$HOME/.local/share/cps-bin}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${BLUE}▸${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$*"; }
die()   { printf "${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }

command -v git &>/dev/null || die "git is required"

if [[ -d "$INSTALL_DIR" ]]; then
  info "Updating existing installation..."
  git -C "$INSTALL_DIR" pull -q
else
  info "Cloning cps..."
  git clone -q "$REPO" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/bin/cps"

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
ln -sf "$INSTALL_DIR/bin/cps" "$BIN_DIR/cps"

ok "Installed cps to $BIN_DIR/cps"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  echo ""
  info "Add to your PATH (if not already):"
  printf "  ${BOLD}export PATH=\"%s:\$PATH\"${RESET}\n" "$BIN_DIR"
fi

echo ""
info "Next steps:"
printf "  ${BOLD}cps init${RESET}                        # Initialize\n"
printf "  ${BOLD}eval \"\$(cps shell-init)\"${RESET}        # Add to .zshrc/.bashrc\n"
echo ""
ok "Done!"
