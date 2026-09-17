#!/usr/bin/env bash
# Laptop-side setup for driving dev containers on geekom. Idempotent.
#
#   ./laptop-setup.sh
#
# Installs the pixels CLI via mise, points it at the box's Incus daemon, and
# adds the SSH block that makes `ssh px-<name>` reach a container on the NAT'd
# bridge. Run this once per laptop; base-setup.sh then builds the image itself.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIXELS_VERSION="${PIXELS_VERSION:-0.6.2}"
BOX_HOST="${BOX_HOST:-geekom.local}"

step() { echo; echo "==> $*"; }

command -v mise >/dev/null || { echo "mise is required (tools come from mise, not brew)."; exit 1; }

# ------------------------------------------------------------------- pixels
step "pixels $PIXELS_VERSION via mise"
mise use -g "github:deevus/pixels@$PIXELS_VERSION"

# -------------------------------------------------------------- incus remote
step "Checking the Incus remote"
# The CSV name column carries a " (current)" suffix on the default remote,
# so match the bare name rather than the whole field.
if ! incus remote list --format csv 2>/dev/null | cut -d, -f1 | sed 's/ (current)$//' | grep -qx box; then
  echo "No 'box' Incus remote yet. Run bootstrap.sh first, or:"
  echo "  incus remote add box $BOX_HOST --token <token> --accept-certificate"
  exit 1
fi
incus list >/dev/null 2>&1 || { echo "Incus remote 'box' is not reachable."; exit 1; }
echo "Incus remote OK."

# ------------------------------------------------------------- pixels config
# pixels reads os.UserConfigDir(), which is ~/Library/Application Support on
# macOS and ~/.config on Linux. Keep the real file in ~/.config either way and
# symlink it on macOS so it lives with the rest of the dotfiles.
step "pixels config"
mkdir -p "$HOME/.config/pixels"
if [[ -e "$HOME/.config/pixels/config.toml" ]] && \
   ! cmp -s "$HERE/pixels-config.toml" "$HOME/.config/pixels/config.toml"; then
  cp "$HOME/.config/pixels/config.toml" "$HOME/.config/pixels/config.toml.bak"
  echo "Existing config backed up to config.toml.bak"
fi
cp "$HERE/pixels-config.toml" "$HOME/.config/pixels/config.toml"

if [[ "$(uname -s)" == "Darwin" ]]; then
  APP_SUPPORT="$HOME/Library/Application Support/pixels"
  if [[ -e "$APP_SUPPORT" && ! -L "$APP_SUPPORT" ]]; then
    echo "NOTE: $APP_SUPPORT exists and is not a symlink; leaving it alone."
    echo "      pixels will read that copy, not ~/.config/pixels."
  else
    ln -sfn "$HOME/.config/pixels" "$APP_SUPPORT"
  fi
fi

# ----------------------------------------------------------------- ssh block
step "SSH config for px-* containers"
mkdir -p "$HOME/.ssh/config.d"
cp "$HERE/pixels-ssh.conf" "$HOME/.ssh/config.d/pixels"
chmod 0600 "$HOME/.ssh/config.d/pixels"

# The Include has to sit above every Host block or it is never consulted.
if ! grep -q 'config.d' "$HOME/.ssh/config" 2>/dev/null; then
  cp "$HOME/.ssh/config" "$HOME/.ssh/config.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  python3 - "$HOME/.ssh/config" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True) if p.exists() else []
idx = next((i for i, l in enumerate(lines) if l.startswith("Host ")), len(lines))
lines.insert(idx, "Include ~/.ssh/config.d/*\n\n")
p.write_text("".join(lines))
print("Include added to ~/.ssh/config")
PY
else
  echo "~/.ssh/config already includes config.d"
fi

step "Done"
echo "Next: build the image with"
echo "  pixels create base"
echo "  incus file push base-setup.sh px-base/root/base-setup.sh"
echo "  incus exec px-base -- bash /root/base-setup.sh"
