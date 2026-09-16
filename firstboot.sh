#!/usr/bin/env bash
# First-boot setup: Debian 13 (trixie) headless -> ZFS + Tailscale + Incus
#
# Usage (as root):
#   ./firstboot.sh /dev/nvme0n1p4 yourusername
#
#   arg1 = raw, unformatted partition to hand to Incus as a ZFS pool
#   arg2 = your non-root login user (gets sudo + incus-admin)
#
# Check the partition name with:  lsblk -f
# It should show no FSTYPE. The script verifies this before touching it.

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ZFS_DEV="${1:?Usage: $0 /dev/<partition> <username>}"
USERNAME="${2:?Usage: $0 /dev/<partition> <username>}"
ARC_MAX_GB=4

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -b "$ZFS_DEV" ]] || { echo "$ZFS_DEV is not a block device."; exit 1; }
id "$USERNAME" >/dev/null 2>&1 || { echo "User $USERNAME does not exist."; exit 1; }

if command -v mokutil >/dev/null 2>&1 || apt-get -y install mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
    echo "Secure Boot is enabled. The ZFS DKMS module will not load."
    echo "Either disable Secure Boot in the BIOS, or enroll the DKMS key:"
    echo "  sudo mokutil --import /var/lib/dkms/mok.pub   (then reboot and enroll at the MOK screen)"
    echo "Set SKIP_SB_CHECK=1 to proceed anyway (e.g. after enrolling the key)."
    [[ "${SKIP_SB_CHECK:-0}" == "1" ]] || exit 1
  fi
fi

FSTYPE=$(blkid -o value -s TYPE "$ZFS_DEV" 2>/dev/null || true)
if [[ "$FSTYPE" == "zfs_member" ]]; then
  echo "$ZFS_DEV already holds a ZFS pool (likely from a previous run); reusing it."
elif [[ -n "$FSTYPE" ]]; then
  echo "$ZFS_DEV already has a filesystem on it: $FSTYPE"
  echo "Refusing to continue. Wipe it deliberately (wipefs -a $ZFS_DEV) if that's intended."
  exit 1
fi

CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
ARCH=$(dpkg --print-architecture)
export DEBIAN_FRONTEND=noninteractive

echo "==> Enabling contrib + non-free-firmware in apt sources"
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  # deb822 format: append missing components to every Components: line
  sed -i -E '/^Components:/{/\bcontrib\b/! s/$/ contrib/}' /etc/apt/sources.list.d/debian.sources
  sed -i -E '/^Components:/{/\bnon-free-firmware\b/! s/$/ non-free-firmware/}' /etc/apt/sources.list.d/debian.sources
fi
if [[ -f /etc/apt/sources.list ]] && grep -qE '^deb ' /etc/apt/sources.list; then
  # classic format: append missing components to every active deb line
  sed -i -E '/^deb /{/\bcontrib\b/! s/$/ contrib/}' /etc/apt/sources.list
  sed -i -E '/^deb /{/\bnon-free-firmware\b/! s/$/ non-free-firmware/}' /etc/apt/sources.list
fi
apt-get update
if ! apt-cache show zfs-dkms >/dev/null 2>&1; then
  echo "ERROR: zfs-dkms still not visible after enabling contrib. Current sources:"
  cat /etc/apt/sources.list 2>/dev/null; cat /etc/apt/sources.list.d/debian.sources 2>/dev/null
  exit 1
fi

echo "==> Base packages"
apt-get update
apt-get -y full-upgrade
apt-get -y install \
  sudo curl gnupg ca-certificates git vim htop tmux jq rsync \
  "linux-headers-$ARCH" dkms

usermod -aG sudo "$USERNAME"

echo "==> SSH: keys only (bootstrap.sh verified key login before running this)"
cat > /etc/ssh/sshd_config.d/10-keys-only.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
systemctl reload ssh

echo "==> mDNS: advertise and resolve <hostname>.local"
apt-get -y install avahi-daemon libnss-mdns
# libnss-mdns adds mdns4_minimal to /etc/nsswitch.conf on install; make sure it's there
grep -qE '^hosts:.*mdns4_minimal' /etc/nsswitch.conf \
  || sed -i -E 's/^(hosts:\s+files)/\1 mdns4_minimal [NOTFOUND=return]/' /etc/nsswitch.conf
systemctl enable --now avahi-daemon
echo "This box is reachable as $(hostname).local"

echo "==> ZFS (dkms build takes a few minutes)"
apt-get -y install zfs-dkms zfsutils-linux
modprobe zfs

echo "==> Capping ZFS ARC at ${ARC_MAX_GB}GB"
cat > /etc/modprobe.d/zfs.conf <<EOF
options zfs zfs_arc_max=$(( ARC_MAX_GB * 1024 * 1024 * 1024 ))
EOF
update-initramfs -u
# apply immediately as well, so no reboot is needed for this
echo $(( ARC_MAX_GB * 1024 * 1024 * 1024 )) > /sys/module/zfs/parameters/zfs_arc_max

echo "==> Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

echo "==> Incus (Zabbly stable repo)"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
cat > /etc/apt/sources.list.d/zabbly-incus-stable.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $CODENAME
Components: main
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
apt-get update
apt-get -y install incus incus-client
usermod -aG incus-admin "$USERNAME"

if incus storage show default >/dev/null 2>&1; then
  echo "==> Incus already initialised; skipping preseed"
else
echo "==> Initialising Incus with ZFS pool on $ZFS_DEV"
incus admin init --preseed <<EOF
config:
  core.https_address: "[::]:8443"
networks:
- name: incusbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: auto
storage_pools:
- name: default
  driver: zfs
  config:
    source: $ZFS_DEV
profiles:
- name: default
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
EOF
fi

echo "==> Shared volumes for caches and repos"
for vol in cache repos; do
  incus storage volume show default "$vol" >/dev/null 2>&1 \
    || incus storage volume create default "$vol"
done

echo "==> 'dev' profile for project containers"
incus profile show dev >/dev/null 2>&1 || incus profile create dev
incus profile set dev limits.cpu=4 limits.memory=6GiB \
  security.nesting=true security.syscalls.intercept.mknod=true \
  security.syscalls.intercept.setxattr=true
for vol in cache repos; do
  incus profile device show dev | grep -q "^$vol:" \
    || incus profile device add dev "$vol" disk pool=default source="$vol" path="/$vol"
done

echo
echo "================================================================"
echo "firstboot.sh complete. If you ran this by hand (not via bootstrap.sh):"
echo "  - optional remote access:   tailscale up --ssh"
echo "  - trust your laptop:        incus config trust add <laptop-name>"
echo "    then on the laptop:       incus remote add box $(hostname).local --token <token>"
echo "  - reboot once so the ARC cap and group memberships apply cleanly"
echo "================================================================"
