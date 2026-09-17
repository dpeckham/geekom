#!/usr/bin/env bash
# Connect the T3 Code client on this laptop to a dev container, from the CLI.
#
#   ./t3-connect.sh px-foo [local-port]
#
# The desktop app's Settings -> Connections -> Add environment -> SSH flow does
# the same thing through the GUI, and cannot be scripted: the app keeps its
# environments in an encrypted connection-catalog.json and registers only a
# `t3code://app` deep link, with no pairing URL form.
#
# So this takes the other route T3 supports — run the server on the box and
# pair with it — and solves the reachability problem with an SSH tunnel. The
# server binds to loopback inside the container, so it is reachable ONLY
# through this tunnel: not from other containers on the bridge, and not from
# the LAN. (`t3 serve --host 0.0.0.0` would expose it to both.)
#
# Leaves the tunnel running in the background; re-running is safe.

set -euo pipefail

BOX="${1:?Usage: $0 <ssh-alias> [local-port]   (e.g. px-foo 3799)}"
LOCAL_PORT="${2:-3799}"
REMOTE_PORT=3773

step() { echo; echo "==> $*"; }

ssh -o BatchMode=yes -o ConnectTimeout=15 "$BOX" true 2>/dev/null \
  || { echo "Cannot reach $BOX over SSH."; exit 1; }

step "Starting t3 server on $BOX (loopback only)"
# Test the port rather than pgrep: this whole script arrives as the remote
# shell's command line, so `pgrep -f "t3 serve"` matches the shell running it
# and the server never starts.
ssh -o BatchMode=yes "$BOX" "
  listening() { ss -lnt 2>/dev/null | grep -q ':$REMOTE_PORT '; }
  if ! listening; then
    nohup t3 serve --host 127.0.0.1 --port $REMOTE_PORT >/tmp/t3-serve.log 2>&1 &
    for i in \$(seq 1 25); do listening && break; sleep 1; done
  fi
  if listening; then
    echo '    listening on 127.0.0.1:$REMOTE_PORT'
  else
    echo '    server did not come up:'; tail -5 /tmp/t3-serve.log 2>/dev/null; exit 1
  fi
"

step "Tunnelling localhost:$LOCAL_PORT -> $BOX:$REMOTE_PORT"
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "    port $LOCAL_PORT already in use; assuming the tunnel is up"
else
  # Detach the tunnel's descriptors. `ssh -f` backgrounds itself but inherits
  # stdout/stderr, so anything capturing this script's output waits on a pipe
  # that never closes.
  ssh -f -N -L "$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" "$BOX" </dev/null >/dev/null 2>&1
  echo "    tunnel established"
fi

step "Minting a pairing token"
# The URL t3 prints points at the container's bridge IP, which this laptop
# cannot route to; the token is what matters, so rebuild the URL against the
# tunnel instead.
token=$(ssh -o BatchMode=yes "$BOX" "t3 pair --ttl 15m --label '$(hostname -s)'" 2>/dev/null \
        | sed -n 's/^Token: *//p' | head -1)
[[ -n "$token" ]] || { echo "Could not mint a pairing token."; exit 1; }

url="http://127.0.0.1:$LOCAL_PORT/pair#token=$token"
step "Opening the T3 client"
echo "    $url"
open "$url" 2>/dev/null || echo "    (open it by hand)"

echo
echo "Tunnel stays up in the background. To drop it:"
echo "  pkill -f 'ssh -f -N -L $LOCAL_PORT:127.0.0.1:$REMOTE_PORT'"
