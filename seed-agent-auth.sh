#!/usr/bin/env bash
# Copy this laptop's agent credentials into a dev container.
#
#   ./seed-agent-auth.sh px-foo
#
# claude-code and codex both use OAuth subscription auth, and neither can read
# it from an env var in the sessions that matter here: Claude Code keeps it in
# the macOS Keychain (a plain file on Linux), and codex has no headless token
# at all for ChatGPT sign-in -- only `--with-api-key`, which is a different
# billing path. So the credentials have to be copied as files.
#
# They are seeded per container at create time rather than baked into the
# `ready` checkpoint, so the template stays credential-free and a throwaway or
# --egress agent box can simply be created with --no-auth.
#
# Credentials are streamed over SSH straight into the container; nothing is
# written to a temp file on this laptop, and no value is ever printed.

set -euo pipefail

BOX="${1:?Usage: $0 <ssh-alias>   (e.g. px-foo)}"

step() { echo "==> $*"; }
warn() { echo "    skipped: $*"; }

ssh -o BatchMode=yes -o ConnectTimeout=15 "$BOX" true 2>/dev/null \
  || { echo "Cannot reach $BOX over SSH."; exit 1; }

# ------------------------------------------------------------------- claude
# macOS keeps this in the login keychain; Linux keeps the same JSON on disk.
# Either way the payload is {"claudeAiOauth": {...}} and Claude Code on the
# container reads it from ~/.claude/.credentials.json.
step "claude-code"
claude_creds=""
if [[ "$(uname -s)" == "Darwin" ]]; then
  claude_creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
elif [[ -f "$HOME/.claude/.credentials.json" ]]; then
  claude_creds=$(cat "$HOME/.claude/.credentials.json")
fi

if [[ -n "$claude_creds" ]] && jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1 <<<"$claude_creds"; then
  printf '%s' "$claude_creds" | ssh -o BatchMode=yes "$BOX" \
    'install -d -m 700 ~/.claude && umask 077 && cat > ~/.claude/.credentials.json'
  exp=$(jq -r '.claudeAiOauth.expiresAt // empty' <<<"$claude_creds")
  if [[ -n "$exp" ]]; then
    # expiresAt is epoch milliseconds.
    echo "    seeded (access token expires $(date -r $((exp/1000)) '+%Y-%m-%d %H:%M'))"
  else
    echo "    seeded"
  fi
else
  warn "no Claude credentials found; run 'claude' once on this laptop to log in"
fi

# -------------------------------------------------------------------- codex
step "codex"
if [[ -f "$HOME/.codex/auth.json" ]]; then
  ssh -o BatchMode=yes "$BOX" \
    'install -d -m 700 ~/.codex && umask 077 && cat > ~/.codex/auth.json' < "$HOME/.codex/auth.json"
  echo "    seeded ($(jq -r '.auth_mode // "unknown"' "$HOME/.codex/auth.json") mode)"
else
  warn "no ~/.codex/auth.json; run 'codex login' on this laptop first"
fi

step "Done"
echo "Verify with:  ssh $BOX 'codex login status'"
