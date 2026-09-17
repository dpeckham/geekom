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

For the scripted dev image see **Dev base image** above. By hand:

```
incus stop proj-base
incus publish proj-base --alias dev-base
incus launch dev-base proj-new --profile default --profile dev
```

### Need a VM instead (kernel isolation, awkward Docker stacks)

```
incus launch images:debian/13 proj-vm --vm --profile default -c limits.memory=8GiB
```

## Dev base image

Project containers are clones of one template: the `base` container's `ready`
checkpoint. [pixels](https://github.com/deevus/pixels) drives the lifecycle —
it talks to this box's Incus daemon over HTTPS from the laptop, snapshots with
ZFS, and can put an nftables egress allowlist around each container.

Tools inside the image are managed by mise, so versions live in one manifest
(`/home/pixel/.config/mise/config.toml`, written by `base-setup.sh`) rather
than being scattered across install commands.

The image carries both the control planes (herdr, T3 Code) and the agents they
drive (`claude-code`, `codex`, `opencode`). The agents are declared explicitly
because `provision.devtools` is off — pixels would otherwise have installed
that set, and without them T3 Code connects to a box with no providers and
shows an empty shell.

| File | Runs on | Does |
|------|---------|------|
| `laptop-setup.sh` | laptop | installs pixels via mise, writes the pixels config + the `px-*` SSH block |
| `base-setup.sh`   | container (root) | installs git, gh, mise, herdr, t3, and the agent CLIs |
| `newbox.sh`       | laptop | clones the base, fixes up SSH, seeds agent creds, registers with herdr |
| `seed-agent-auth.sh` | laptop | copies this laptop's claude/codex credentials into a box |
| `pixels-config.toml` / `pixels-ssh.conf` | laptop | the two config files the setup script installs |

### Why Debian, not Alpine or NixOS

The toolchain decides this. Every tool here is a prebuilt binary fetched at
runtime, and only one of them is portable:

| Tool | Linux build | musl (Alpine) | NixOS |
|------|-------------|---------------|-------|
| herdr | static-pie musl | works | works |
| t3    | dynamic, needs `GLIBC_2.28`+ | **no** | needs `nix-ld` |
| mise runtimes | prebuilt glibc node/python | **no** | needs `nix-ld` |

`t3` links `/lib64/ld-linux-x86-64.so.2` and bundles only
`@yuuang/ffi-rs-linux-x64-gnu` — there is no musl build to fall back to, and
its installer picks on `uname -s`/`uname -m` alone. Alpine would cost t3
entirely to save ~80MB on a 1.9TB pool. NixOS fails for the same reason
(no `/lib64/ld-linux-x86-64.so.2`), and since mise would still be managing the
toolchain, its declarative half would only cover git, openssh and nix-ld.

Debian 13 matches the host and ships a newer git than Ubuntu 24.04 (2.47 vs
2.43). Swap `defaults.image` in `pixels-config.toml` to change it.

### Build it

```
./laptop-setup.sh                 # once per laptop
pixels create base
incus file push base-setup.sh px-base/root/base-setup.sh
incus exec px-base -- bash /root/base-setup.sh
```

Then finalise and snapshot. Removing the host keys is what lets each clone
generate its own identity on first boot. Quote the glob — unquoted, your local
shell expands it against the laptop's `/etc/ssh` and the container's keys are
never touched:

```
incus exec px-base -- bash -c 'rm -f /root/base-setup.sh /etc/ssh/ssh_host_*'
pixels checkpoint create base --label ready
```

### Use it

```
./newbox.sh foo                   # clone -> ssh -> agent creds -> herdr
./newbox.sh foo --egress agent    # ...with the outbound allowlist on
./newbox.sh foo --no-auth         # ...without seeding your agent credentials
```

Cloning is a ZFS snapshot, so it takes about a second. Then:

```
ssh px-foo                        # via ProxyJump through geekom
pixels console foo                # no SSH at all; native Incus exec
pixels list / pixels destroy foo
```

For T3 Code, run the server on the box and pair from the laptop or phone:

```
ssh px-foo 't3 serve --host 0.0.0.0'   # :3773
ssh px-foo 't3 pair'                   # prints a pairing link/QR
```

### Updating the image

`base-setup.sh` is idempotent, so updating means re-running it on the template
and taking a fresh checkpoint. Existing project containers are unaffected —
they are already-diverged clones.

```
pixels start base || true                          # errors if already running
incus file push base-setup.sh px-base/root/base-setup.sh
incus exec px-base -- bash /root/base-setup.sh
incus exec px-base -- bash -c 'rm -f /root/base-setup.sh /etc/ssh/ssh_host_*'
pixels checkpoint delete base ready
pixels checkpoint create base --label ready
```

`gh`, `herdr` and `node` are pinned to `latest` and move on their own. **t3 is
pinned by exact version**, because it is installed from a release tarball URL
rather than a registry — bump `T3_VERSION` at the top of `base-setup.sh` and
re-run. Check <https://github.com/pingdotgg/t3code/releases> for the current
one.

### Connecting T3 Code to a box

In the T3 Code desktop app: Settings -> Connections -> Add environment -> SSH,
and enter the alias (`px-foo`, or `pixel@px-foo`) — **not** the IP that
`pixels list` prints.

An IP does not match the `Host px-*` pattern, so ssh applies no ProxyCommand
and tries the NAT'd bridge directly, which fails like this:

```
Could not prepare the SSH environment: ... SshCommandError:
ssh: connect to host 10.185.22.87 port 22: Operation timed out
```

The fix is always to use the alias, which is what pulls in the hop.

The app shells out to the system `ssh` — its bundle builds
`ssh -o BatchMode=… -o ControlMaster=no` command lines and carries no JS ssh
library — so it reads `~/.ssh/config` and the `px-*` block below applies,
NAT and all. `BatchMode` forbids interactive prompts, so the hop has to work
non-interactively; it does, with keys coming from the 1Password agent. On
first connect the app installs its own runtime to `~/.t3/runtime` on the
container, which is why `curl`, `tar` and `sha256sum` are in the base image.

From a phone the pairing flow (`t3 serve` + `t3 pair`) needs the device to
reach `10.185.22.x`, which the LAN cannot — that path wants Tailscale in the
container (`t3 pair --tailscale`).

### Agent credentials

`claude` and `codex` are both signed in from this laptop's credentials when a
box is created, so there is nothing to log into per container.

Neither tool can take its subscription auth from an env var in the sessions
that matter here. Claude Code keeps it in the macOS Keychain (a plain file on
Linux) and reads `~/.claude/.credentials.json` on the container; codex has no
headless token for ChatGPT sign-in at all — only `--with-api-key`, which is a
different billing path — so its `~/.codex/auth.json` has to be copied. That is
all `seed-agent-auth.sh` does, streaming both straight over SSH so nothing is
written to a temp file and no value is ever printed. Both land mode 600.

Credentials are seeded per container rather than baked into the `ready`
checkpoint, so the template stays credential-free and nothing long-lived sits
in a ZFS snapshot that every clone inherits.

**This hands live subscription tokens to anything with a shell on the box.**
That is usually what you want on a box you drive yourself, and not what you
want around an unattended agent — `./newbox.sh foo --no-auth` skips it, and
`./seed-agent-auth.sh px-foo` can add them later.

Re-seed an existing box the same way; the access token is short-lived and each
container refreshes its own copy independently.

### How the laptop reaches a container

Containers live on `incusbr0` (10.185.22.0/24), NAT'd behind geekom and not
routable from the laptop. `pixels console` sidesteps this entirely (Incus exec
API over HTTPS), but herdr and t3 both need real SSH, so `pixels-ssh.conf`
hops through the box:

```
ProxyCommand ssh dpeckham@geekom.local 'nc $(dig +short %h.incus @10.185.22.1 | head -n1) 22'
```

The box has no systemd-resolved, so its own resolver cannot be taught the
`.incus` zone; asking the bridge's dnsmasq directly avoids configuring
anything on the box and keeps container IPs dynamic.

Host keys are kept in `~/.ssh/known_hosts.pixels`. Since every clone
regenerates its host key and names get recycled, `newbox.sh` clears the stale
entry on each create. Do not set `UserKnownHostsFile=/dev/null` to avoid that
— `herdr machine add` fails with "lost connection to server" when host keys
are not persisted.

Agent forwarding is deliberately off: these containers run AI coding agents,
and forwarding the 1Password agent would hand them your keys. Use `gh auth
login` or a scoped deploy key inside the container.

### Egress allowlist

`--egress agent` installs an nftables ruleset (default `policy drop`, with the
resolved allowlist in an `allowed_v4` set) and swaps the blanket `NOPASSWD`
sudo for a restricted one, so an agent cannot switch the firewall off. Package
installs then go through the wrapper rather than apt directly:

```
sudo safe-apt update
```

The stock preset covers the AI APIs, npm/PyPI/crates/Go, GitHub and the Ubuntu
mirrors. `pixels-config.toml` adds what this setup needs on top:
`deb.debian.org` and `security.debian.org` (the preset has only Ubuntu
mirrors), plus `herdr.dev` and `t3.codes` — without those two,
`herdr machine add` and t3 pairing fail. Note the allowlist is IPv4-only; the
chain is `policy drop` on an `inet` table, so IPv6 is dropped rather than
allowed through (fail-closed, and moot here since the bridge hands out a ULA
with no upstream route).

### Gotchas

Three things here were found the hard way and will look like unrelated
breakage if you hit them cold.

**pixels 0.6.2 silently half-provisions.** Leave `provision.devtools = false`.
With it enabled, the Incus backend pushes
`/home/pixel/.config/mise/config.toml` without creating the parent directory;
the Incus file API does not create parents, and the error is discarded by
`_ = err` in `sandbox/incus/backend.go`. Provisioning aborts *before*
`rc.local` runs, so the container comes up with no `pixel` user and no sshd
while `pixels create` still reports success. `base-setup.sh` installs a fuller
toolchain than the devtools step would anyway.

**t3 must not be installed from npm.** mise's npm backend does not fetch
node-pty's native module, so `npm:t3` yields a `t3` that answers
`t3 --version` but dies on `t3 serve` with "Failed to load native module:
pty.node". The vendor's release tarball ships `build/Release/pty.node` and its
own client assets, so it is installed through mise's `http` backend with
`bin_path` pointing at the extracted directory rather than a lone binary.

**Do not stop persisting SSH host keys.** Every clone regenerating its own host
key (see above) makes `~/.ssh/known_hosts.pixels` go stale whenever a name is
reused, and the obvious fix — `UserKnownHostsFile=/dev/null` — breaks
`herdr machine add` with "lost connection to server". `newbox.sh` clears the
stale entry at create time instead.

One non-issue worth recording, since it looks alarming: under `--egress agent`,
`sudo apt-get update` fails with a password prompt. That is not the firewall.
pixels deliberately replaces blanket `NOPASSWD` sudo with a restricted list so
an agent cannot disable nftables; use `sudo safe-apt` instead.

## Maintenance

- Host updates: `ssh geekom.local`, `sudo apt update && sudo apt full-upgrade`.
  A kernel update triggers a ZFS DKMS rebuild; reboot after.
- Pool health: `sudo zpool status` on the box.
- Backups: `incus export proj-foo proj-foo.tar.gz` for a container;
  `incus storage volume export default repos repos.tar.gz` for shared data.
- Dev image: see **Updating the image** above; the host's `apt full-upgrade`
  does not touch containers.
- If the box's IP changes and the remote is pinned to it:
  `incus remote set-url box https://geekom.local:8443`
