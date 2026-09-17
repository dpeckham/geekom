#!/usr/bin/env bash
# Toolchain for the dev base image. Runs INSIDE a pixels container, as root.
#
#   incus file push base-setup.sh px-base/root/base-setup.sh
#   incus exec px-base -- bash /root/base-setup.sh
#
# Installs git + gh + mise + herdr + t3 and the agent CLIs (claude-code,
# codex, opencode) for the `pixel` user. Idempotent.
#
# Everything above the system layer goes through mise so there is exactly one
# place to bump a version: /home/pixel/.config/mise/config.toml, which this
# script writes. mise itself comes from its Debian repo rather than
# `curl https://mise.run | sh` so the install is apt- and GPG-verified.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PIXEL_USER=pixel
PIXEL_HOME="/home/$PIXEL_USER"

# T3 Code has no mise registry entry, so its release tarball is pinned here.
# Check https://github.com/pingdotgg/t3code/releases for newer versions.
T3_VERSION="${T3_VERSION:-0.0.42}"

[[ $EUID -eq 0 ]] || { echo "Run as root inside the container."; exit 1; }
id "$PIXEL_USER" >/dev/null 2>&1 || {
  echo "User $PIXEL_USER does not exist — did pixels provisioning run?"; exit 1; }

step() { echo; echo "==> $*"; }

# --------------------------------------------------------------- system layer
step "Base packages"
apt-get update -qq
# nftables is here rather than pulled on demand because `pixels network set
# <box> agent` shells out to apt to install it, which fails on a container that
# has no package lists -- exactly the state a freshly cloned template is in.
apt-get install -y -qq \
  git curl ca-certificates gnupg build-essential \
  jq unzip openssh-server sudo nftables

# ------------------------------------------------------------------ mise (apt)
step "mise (apt repo, GPG-verified)"
install -dm 755 /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/mise-archive-keyring.gpg ]]; then
  curl -fsSL https://mise.jdx.dev/gpg-key.pub \
    | gpg --dearmor -o /etc/apt/keyrings/mise-archive-keyring.gpg
fi
ARCH=$(dpkg --print-architecture)
echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=$ARCH] https://mise.jdx.dev/deb stable main" \
  > /etc/apt/sources.list.d/mise.list
apt-get update -qq
apt-get install -y -qq mise

# ------------------------------------------------------------- managed tools
# node is explicit because the agent CLIs you'll add later (claude-code,
# codex, opencode) all want a runtime, and t3's client assets assume one.
step "mise tool manifest"
case "$ARCH" in
  amd64) T3_ARCH=x64 ;;
  arm64) T3_ARCH=arm64 ;;
  *) echo "No T3 Code release for arch $ARCH"; exit 1 ;;
esac
# Create .config explicitly: `install -d` only applies -o/-g to the final
# component, so creating .config/mise in one shot leaves .config owned by root
# and every later tool that wants ~/.config/<name> (herdr's socket dir, gh's
# hosts file) fails with EACCES.
install -d -o "$PIXEL_USER" -g "$PIXEL_USER" -m 755 "$PIXEL_HOME/.config"
install -d -o "$PIXEL_USER" -g "$PIXEL_USER" -m 755 "$PIXEL_HOME/.config/mise"
cat > "$PIXEL_HOME/.config/mise/config.toml" <<EOF
[tools]
node = "lts"

# Source control
gh = "latest"

# Agent control planes
herdr = "latest"   # terminal workspace manager (aqua:ogulcancelik/herdr)

# The agents themselves. herdr and T3 Code are control planes -- they drive
# these and show an empty shell without them. pixels' own devtools step would
# have installed this set, and it is disabled here (see pixels-config.toml),
# so they have to be declared explicitly.
claude-code = "latest"
codex       = "latest"
opencode    = "latest"

# T3 Code comes from the vendor's release tarball, not npm. The npm package is
# a launcher whose node-pty native module mise's npm backend does not fetch, so
# \`t3 serve\` dies on "Failed to load native module: pty.node". The release
# tarball ships build/Release/pty.node and its own client assets, so bin_path
# points at the extracted dir rather than a lone binary.
# Bumping t3 means bumping T3_VERSION at the top of this script.
[tools."http:t3"]
version  = "$T3_VERSION"
url      = "https://github.com/pingdotgg/t3code/releases/download/v$T3_VERSION/t3-$T3_VERSION-linux-$T3_ARCH.tar.gz"
bin_path = "t3-$T3_VERSION-linux-$T3_ARCH"
EOF
chown "$PIXEL_USER:$PIXEL_USER" "$PIXEL_HOME/.config/mise/config.toml"

step "Installing tools via mise (this pulls node first)"
su - "$PIXEL_USER" -c 'mise trust --yes ~/.config/mise/config.toml' || true
su - "$PIXEL_USER" -c 'mise install --yes'

# mise activation for interactive shells; the shims dir keeps non-interactive
# `ssh host t3 ...` working too, which is how herdr and t3 get driven remotely.
if ! grep -q 'mise activate bash' "$PIXEL_HOME/.bashrc" 2>/dev/null; then
  cat >> "$PIXEL_HOME/.bashrc" <<'EOF'

# mise
eval "$(mise activate bash)"
EOF
  chown "$PIXEL_USER:$PIXEL_USER" "$PIXEL_HOME/.bashrc"
fi
cat > /etc/profile.d/mise-shims.sh <<'EOF'
# Make mise-managed tools resolvable in login shells.
case ":$PATH:" in
  *":$HOME/.local/share/mise/shims:"*) ;;
  *) [ -d "$HOME/.local/share/mise/shims" ] && PATH="$HOME/.local/share/mise/shims:$PATH" ;;
esac
export PATH
EOF
chmod 0644 /etc/profile.d/mise-shims.sh

# profile.d only covers login shells. `ssh host <cmd>` is neither login nor
# interactive, and the stock Debian/Ubuntu .bashrc returns early when it is
# not interactive —
# so neither file runs. That is precisely how `herdr --remote` and T3 Code's
# SSH transport invoke things, so the shims have to be on PATH before any
# shell starts. sshd runs PAM, and pam_env reads /etc/environment, which
# applies to non-interactive sessions too.
SHIMS="$PIXEL_HOME/.local/share/mise/shims"
if [[ -f /etc/environment ]] && grep -q '^PATH=' /etc/environment; then
  if ! grep -q "$SHIMS" /etc/environment; then
    sed -i -E "s|^PATH=\"?([^\"]*)\"?$|PATH=\"$SHIMS:\1\"|" /etc/environment
  fi
else
  echo "PATH=\"$SHIMS:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" >> /etc/environment
fi

# ------------------------------------------------------- ssh host key hygiene
# Every clone of this template would otherwise ship the template's SSH host
# keys, so all containers would present one identity and none could be told
# apart -- a compromised one could impersonate any other. The keys are removed
# just before checkpointing (see README); this unit regenerates them on first
# boot of each clone. Debian 13 and Ubuntu 24.04 both socket-activate sshd, so
# order against ssh.socket as well as ssh.service.
step "SSH host key regeneration on first boot"
cat > /etc/systemd/system/regenerate-ssh-host-keys.service <<'EOF'
[Unit]
Description=Regenerate SSH host keys when absent (fresh identity per clone)
Before=ssh.service ssh.socket

# No ConditionPathExistsGlob here: the negated-glob form evaluated false even
# with /etc/ssh empty, so the unit was skipped on boot. `ssh-keygen -A` only
# creates key types that are missing, so it is already idempotent and needs no
# guard.

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable regenerate-ssh-host-keys.service >/dev/null 2>&1 || true

# ------------------------------------------------------------------------ git
step "git defaults"
su - "$PIXEL_USER" -c 'git config --global init.defaultBranch main'
# Scoped to the shared volume rather than "*": a blanket safe.directory turns
# off git's ownership check everywhere, which matters more than usual in a box
# an agent has a shell on. Harmless when /repos is not mounted.
su - "$PIXEL_USER" -c 'git config --global --add safe.directory "/repos/*"'

step "Done"
su - "$PIXEL_USER" -c 'mise ls' || true
