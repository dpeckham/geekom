#!/usr/bin/env bash
# Copy this laptop's agent + GitHub credentials into a dev container.
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

# ----------------------------------------------------------------------- gh
# The base image ships gh but no credentials, so a fresh box cannot clone a
# private repo. The laptop keeps its token in the macOS keyring, so pull it
# out with `gh auth token` and hand it to the container over stdin -- never as
# an argv value, which would be visible in the container's process list.
step "gh"
if command -v gh >/dev/null && gh_token=$(gh auth token 2>/dev/null) && [[ -n "$gh_token" ]]; then
  printf '%s' "$gh_token" | ssh -o BatchMode=yes "$BOX" \
    'gh auth login --hostname github.com --with-token >/dev/null 2>&1 && gh auth setup-git >/dev/null 2>&1'
  echo "    seeded ($(ssh -o BatchMode=yes "$BOX" 'gh auth status 2>&1 | grep -oE "account [^ ]+" | head -1' 2>/dev/null))"
else
  warn "no gh token on this laptop; run 'gh auth login' here first"
fi

step "Done"
echo "Verify with:  ssh $BOX 'codex login status; gh auth status'"
