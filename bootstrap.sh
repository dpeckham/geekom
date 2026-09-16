#!/usr/bin/env bash
# Run this from your LAPTOP. It provisions a freshly installed Debian 13 box.
#
# Usage:
#   ./bootstrap.sh <host-or-ip> <username> <zfs-partition> [remote-name]
#   NO_TAILSCALE=1 ./bootstrap.sh ...     (LAN only, skip the tailnet step)
#
#   host           the new box (LAN IP or hostname), reachable via SSH right now
#   username       the non-root user created during the Debian install
#   zfs-partition  raw, unformatted partition for Incus, e.g. /dev/nvme0n1p3
#   remote-name    what to call it in `incus remote` (default: box)
#
# What it does:
#   1. copies your SSH public key to the box
#   2. uploads firstboot.sh and runs it as root (via sudo or su, whichever works)
#      (firstboot.sh also switches sshd to key-only auth at that point)
#   3. runs `tailscale up` interactively so you can approve it in your browser
#      (skip with NO_TAILSCALE=1)
#   4. creates an Incus trust token and registers the box as a remote on this laptop
#   5. reboots the box once
#
# You'll be prompted for a password up to three times: once by ssh-copy-id,
# once for sudo/root when firstboot.sh runs, and once for sudo at the reboot
# (plus once more for tailscale if enabled). No passwordless sudo is configured.
#
# Requires on the laptop: ssh, ssh-copy-id, scp, and the `incus` client.

set -euo pipefail

HOST="${1:?Usage: $0 <host> <username> <zfs-partition> [remote-name]}"
USERNAME="${2:?Usage: $0 <host> <username> <zfs-partition> [remote-name]}"
ZFS_DEV="${3:?Usage: $0 <host> <username> <zfs-partition> [remote-name]}"
REMOTE="${4:-box}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT="$HERE/firstboot.sh"
TARGET="$USERNAME@$HOST"
SSH="ssh -o StrictHostKeyChecking=accept-new $TARGET"

[[ -f "$FIRSTBOOT" ]] || { echo "firstboot.sh not found next to this script."; exit 1; }
command -v incus >/dev/null || echo "WARNING: no 'incus' client on this laptop; step 4 will be skipped."

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- 1. SSH key
step "Copying SSH key to $TARGET (you'll be asked for the password once)"
if [[ ! -f "$HOME/.ssh/id_ed25519.pub" && ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
  echo "No SSH key found; generating one."
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
ssh-copy-id -o StrictHostKeyChecking=accept-new "$TARGET"
$SSH true && echo "Key auth works."

# ---------------------------------------------------- 2. run firstboot as root
step "Uploading firstboot.sh"
scp -q "$FIRSTBOOT" "$TARGET:/tmp/firstboot.sh"

step "Running firstboot.sh as root on the box (this takes several minutes)"
# Fresh Debian: if you set a root password at install, $USERNAME isn't in sudo.
# Try sudo first, fall back to su. -t gives us a tty for the password prompt.
ssh -t "$TARGET" "
  chmod +x /tmp/firstboot.sh
  if id -nG | grep -qw sudo; then
    sudo /tmp/firstboot.sh '$ZFS_DEV' '$USERNAME'
  else
    echo 'Not in sudo group; enter the ROOT password:'
    su - -c \"/tmp/firstboot.sh '$ZFS_DEV' '$USERNAME'\"
  fi
"

# ---------------------------------------------------- 3. tailscale (optional)
# Set NO_TAILSCALE=1 to skip this and use the LAN address for everything.
# Tailscale is still installed by firstboot.sh; run `sudo tailscale up --ssh`
# on the box whenever you want remote access later.
if [[ "${NO_TAILSCALE:-0}" == "1" ]]; then
  step "Skipping Tailscale; using $HOST for Incus and SSH"
  ADDR="$HOST"
  DISPLAY_NAME="$HOST"
else
  step "Joining the tailnet (open the URL it prints, approve, then it continues)"
  ssh -t "$TARGET" "sudo tailscale up --ssh --operator=$USERNAME"
  ADDR=$($SSH "tailscale ip -4" | head -n1)
  DISPLAY_NAME=$($SSH "tailscale status --self --json | jq -r .Self.DNSName | sed 's/\.\$//'")
  echo "Tailscale: $DISPLAY_NAME ($ADDR)"
fi

# ---------------------------------------------------- 4. incus remote
if command -v incus >/dev/null; then
  step "Registering box as Incus remote '$REMOTE' on this laptop"
  LAPTOP_NAME="$(hostname -s)"
  # trust add prints explanatory text; the token is the last non-empty line
  TOKEN=$($SSH "incus config trust add '$LAPTOP_NAME'" | grep -v '^\s*$' | tail -n1)
  if incus remote list --format csv | cut -d, -f1 | grep -qx "$REMOTE"; then
    incus remote remove "$REMOTE"
  fi
  incus remote add "$REMOTE" "$ADDR" --token "$TOKEN" --accept-certificate
  incus remote switch "$REMOTE"
  echo "Default Incus remote is now '$REMOTE'."
fi

# ---------------------------------------------------- 5. reboot
step "Rebooting the box so the ARC cap and group memberships apply cleanly"
ssh -t "$TARGET" "sudo reboot" || true

echo
echo "Waiting for it to come back..."
for i in $(seq 1 60); do
  sleep 5
  if ssh -o ConnectTimeout=3 "$USERNAME@$ADDR" true 2>/dev/null; then
    echo "Back up."
    break
  fi
done

echo
echo "================================================================"
echo "Done."
echo "  SSH:    ssh $USERNAME@$DISPLAY_NAME"
echo "  Incus:  incus list        (remote '$REMOTE' is the default)"
echo
echo "First container:"
echo "  incus launch images:debian/13 proj-test --profile default --profile dev"
echo "  incus exec proj-test -- bash"
echo "================================================================"
