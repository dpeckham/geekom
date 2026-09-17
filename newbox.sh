#!/usr/bin/env bash
# Spin up a project container from the dev base image.
#
#   ./newbox.sh <name> [--egress agent] [--no-herdr]
#
# Clones px-base's `ready` checkpoint (a ZFS snapshot, so this is ~1s), clears
# the stale SSH host key for a recycled name, waits for sshd, and registers the
# box with herdr so it shows up in the sidebar on this laptop.

set -euo pipefail

NAME="${1:?Usage: $0 <name> [--egress agent] [--no-herdr]}"; shift || true
EGRESS=""
REGISTER_HERDR=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --egress) EGRESS="${2:?--egress needs a mode}"; shift 2 ;;
    --no-herdr) REGISTER_HERDR=0; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

BASE="${BASE:-base}"
LABEL="${LABEL:-$NAME}"
HOSTALIAS="px-$NAME"
KNOWN="$HOME/.ssh/known_hosts.pixels"

command -v pixels >/dev/null || { echo "pixels not found; run ./laptop-setup.sh"; exit 1; }

step() { echo; echo "==> $*"; }

step "Cloning $BASE:ready -> $NAME"
pixels create "$NAME" --from "$BASE:ready"

# Each clone regenerates its host key, and names get reused, so an old entry
# here would hard-fail the next connection.
ssh-keygen -R "$HOSTALIAS" -f "$KNOWN" >/dev/null 2>&1 || true

step "Waiting for sshd"
for i in $(seq 1 30); do
  if ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOSTALIAS" true 2>/dev/null; then
    echo "Reachable as $HOSTALIAS"
    break
  fi
  [[ $i -eq 30 ]] && { echo "Timed out waiting for $HOSTALIAS"; exit 1; }
  sleep 3
done

if [[ -n "$EGRESS" ]]; then
  step "Egress: $EGRESS"
  pixels network set "$NAME" "$EGRESS"
fi

if [[ $REGISTER_HERDR -eq 1 ]] && command -v herdr >/dev/null; then
  step "Registering with herdr"
  # A herdr server already running on the box makes `machine add` refuse, and a
  # stale saved entry under the same label would shadow the new one.
  ssh "$HOSTALIAS" 'herdr server stop >/dev/null 2>&1 || true' 2>/dev/null || true
  OLD=$(herdr machine list 2>/dev/null | awk -v h="$HOSTALIAS" '$3==h {print $1}')
  [[ -n "$OLD" ]] && herdr machine remove "$OLD" >/dev/null 2>&1 || true
  herdr machine add "$HOSTALIAS" --label "$LABEL"
fi

step "Ready"
echo "  ssh $HOSTALIAS"
echo "  pixels console $NAME"
echo "  t3:    ssh $HOSTALIAS 't3 serve --host 0.0.0.0'   # then t3 pair"
