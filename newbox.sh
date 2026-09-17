#!/usr/bin/env bash
# Spin up a project container from the dev base image.
#
#   ./newbox.sh <name> [--repo org/repo]... [--egress agent] [--no-herdr] [--no-auth]
#
# Clones px-base's `ready` checkpoint (a ZFS snapshot, so this is ~1s), clears
# the stale SSH host key for a recycled name, waits for sshd, seeds the agent
# credentials, and registers the box with herdr so it shows up in the sidebar
# on this laptop.
#
# --no-auth skips the credential seeding. Use it for a box you do not trust
# with your live Claude/ChatGPT subscription tokens -- anything running an
# unattended agent behind --egress agent is a reasonable candidate, since an
# agent with a shell can read those files.

set -euo pipefail

NAME="${1:?Usage: $0 <name> [--repo org/repo]... [--egress agent] [--no-herdr] [--no-auth]}"; shift || true
EGRESS=""
REGISTER_HERDR=1
SEED_AUTH=1
REPOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --egress) EGRESS="${2:?--egress needs a mode}"; shift 2 ;;
    --no-herdr) REGISTER_HERDR=0; shift ;;
    --no-auth) SEED_AUTH=0; shift ;;
    --repo) REPOS+=("${2:?--repo needs org/repo}"); shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

if [[ $SEED_AUTH -eq 1 && -x "$HERE/seed-agent-auth.sh" ]]; then
  step "Seeding agent credentials"
  "$HERE/seed-agent-auth.sh" "$HOSTALIAS" || echo "    (seeding failed; run seed-agent-auth.sh $HOSTALIAS by hand)"
fi

# Repos land at ~/code/<org>/<repo>, mirroring the laptop. Keeping the org
# level means paths match muscle memory, anything in a repo that refers to a
# sibling by path still resolves, and two repos sharing a name across orgs do
# not collide in a multi-repo box.
for repo in ${REPOS+"${REPOS[@]}"}; do
  org="${repo%%/*}"; name="${repo##*/}"
  if [[ "$org" == "$repo" || -z "$name" ]]; then
    echo "    --repo wants org/repo, got: $repo"; exit 1
  fi
  step "Cloning $repo -> ~/code/$org/$name"
  ssh -o BatchMode=yes "$HOSTALIAS" "
    set -e
    mkdir -p ~/code/$org
    if [ -d ~/code/$org/$name/.git ]; then
      echo '    already present'
    else
      gh repo clone $repo ~/code/$org/$name -- --quiet
    fi
    cd ~/code/$org/$name
    if [ -f mise.toml ] || [ -f .mise.toml ]; then
      mise trust --yes . >/dev/null 2>&1 || true
      echo '    installing toolchain...'
      mise install --yes 2>&1 | tail -3
    fi
  "
done

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
[[ $SEED_AUTH -eq 1 ]] && echo "  agents: claude / codex / gh authenticated from this laptop's credentials"
for repo in ${REPOS+"${REPOS[@]}"}; do
  echo "  repo:   ~/code/${repo%%/*}/${repo##*/}"
done
