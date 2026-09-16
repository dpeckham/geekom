# geekom — Incus dev box

Headless Debian 13 (trixie) on a 32GB / 2TB NVMe machine. Incus manages
LXC containers (and VMs if needed) on a ZFS pool. Everything is driven
from the laptop with the `incus` CLI.

## Layout

| Partition | Size    | Use            |
|-----------|---------|----------------|
| p1        | 1 GB    | EFI (/boot/efi)|
| p2        | 60 GB   | ext4 root      |
| p3        | 8 GB    | swap           |
| p4        | ~1.9 TB | ZFS pool `default` (owned by Incus) |

Shared Incus volumes on the pool, mounted into every `dev`-profile container:

- `cache` → `/cache` — package caches, model weights, anything big and reusable
- `repos` → `/repos` — git checkouts

Host is reachable as `geekom.local` (mDNS). Tailscale is installed but not
enabled; run `sudo tailscale up --ssh` on the box if remote access is wanted.

## Provisioning (one time, or after a reinstall)

Prereqs on the laptop: `ssh`, `ssh-copy-id`, `scp`, and the `incus` client.

1. Install Debian 13 netinst: no desktop, SSH server ticked, manual
   partitioning as above with p4 set to "do not use". **Disable Secure Boot
   in the BIOS** — the ZFS DKMS module won't load with it on.
2. Note the box's LAN IP from the console (`ip a`).
3. From the laptop, with `bootstrap.sh` and `firstboot.sh` in the same dir:

   ```
   NO_TAILSCALE=1 ./bootstrap.sh <ip> <username> /dev/nvme0n1p4
   ```

   Args: LAN IP or hostname, your login user, the raw partition, and
   optionally a remote name (default `box`). Drop `NO_TAILSCALE=1` to join
   the tailnet during setup.

   You'll be prompted for a password a few times (ssh-copy-id, sudo/root for
   firstboot, sudo for reboot). No passwordless sudo is configured.

`bootstrap.sh` copies your SSH key, uploads and runs `firstboot.sh` as root,
registers the box as an Incus remote on the laptop, and reboots it.

`firstboot.sh` (runs on the box as root) enables contrib, installs ZFS,
Avahi/mDNS, Tailscale, and Incus; caps the ZFS ARC at 4GB; switches sshd to
key-only auth; initialises Incus with the ZFS pool, `incusbr0` bridge, the
shared volumes, and the `dev` profile. It's idempotent — safe to rerun.

### If bootstrap didn't finish the remote step

On the box: `incus config trust add laptop` → prints a token.
On the laptop:

```
incus remote add box geekom.local --token <token> --accept-certificate
incus remote switch box
```

If it says the remote exists, `incus remote remove box` first. Tokens are
single-use; make a new one if the old one is rejected.

## Quick start: new dev container

```
incus launch images:debian/13 proj-foo --profile default --profile dev
incus exec proj-foo -- bash
```

Inside: `/cache` and `/repos` are already mounted, networking works, limits
are 4 CPU / 6GB from the `dev` profile. Docker inside the container is
allowed (nesting is enabled).

### Snapshot before letting an agent loose

```
incus snapshot create proj-foo clean      # take
incus snapshot restore proj-foo clean     # roll back
incus snapshot list proj-foo
```

### Everyday commands

```
incus list                                # what's running
incus stop proj-foo / incus start proj-foo
incus delete proj-foo --force             # gone (shared volumes survive)
incus file push ./thing proj-foo/root/    # copy in
incus file pull proj-foo/root/out.txt .   # copy out
incus exec proj-foo -- <cmd>              # run one command
incus config set proj-foo limits.memory=12GiB   # bump a limit
```

### Make a golden template

Set up a container the way you like (toolchain, dotfiles, agent CLIs), then:

```
incus stop proj-base
incus publish proj-base --alias dev-base
incus launch dev-base proj-new --profile default --profile dev
```

### Need a VM instead (kernel isolation, awkward Docker stacks)

```
incus launch images:debian/13 proj-vm --vm --profile default -c limits.memory=8GiB
```

## Maintenance

- Host updates: `ssh geekom.local`, `sudo apt update && sudo apt full-upgrade`.
  A kernel update triggers a ZFS DKMS rebuild; reboot after.
- Pool health: `sudo zpool status` on the box.
- Backups: `incus export proj-foo proj-foo.tar.gz` for a container;
  `incus storage volume export default repos repos.tar.gz` for shared data.
- If the box's IP changes and the remote is pinned to it:
  `incus remote set-url box https://geekom.local:8443`
