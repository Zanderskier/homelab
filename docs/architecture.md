# Architecture and design decisions

How the homelab is put together, and why. The operational how-tos live next to the code:
[hardening.md](hardening.md), [monitoring.md](monitoring.md), [ci-cd.md](ci-cd.md), [secrets.md](secrets.md), [ansible/README.md](../ansible/README.md).

## Hosts

Two Proxmox VE 9 hosts run everything as LXCs (and one VM), split by role:

- **skynet** (Dell Precision 5810, 64 GB ECC, Quadro P2200): media and the heavier services.
  Plex, the *arr stack, Gitea, Authentik, the offline-knowledge LXC (Kiwix), and the two CI
  runners (Docker for lint and Renovate, host-mode for Ansible).
- **little-skynet** (Dell OptiPlex 7050, 16 GB): household apps that should stay up. Portainer
  (the single control plane for every Docker host), Vaultwarden, Paperless-ngx, Mealie, Uptime
  Kuma, cloudflared, and Immich in an Ubuntu VM.

Supporting hardware: a Proxmox Backup Server, a Raspberry Pi 2 (Pi-hole + Unbound), a Raspberry
Pi 4 backup target, and two JetKVMs for out-of-band console access to both Proxmox hosts.

**Why LXCs, mostly:** low overhead and fast backups. Immich is a VM because its upstream install is
docker-compose on a full OS, with its own upgrade path.

## Remote access

| Path | Used for |
|---|---|
| **Cloudflare Tunnel** | Apps that are meant to be reachable from anywhere (Plex, Immich, Vaultwarden, ...) |
| **OpenVPN on the router** | Everything else: admin UIs, SSH, Proxmox |

- **No inbound ports are open.** `cloudflared` makes an outbound connection, and Cloudflare routes
  each public hostname down it to an internal `ip:port`.
- **One tunnel for everything.** It started as 22 tunnels (one per app, tokens committed to Git).
  It's now one tunnel with a route per hostname, so there's one token, kept in Portainer. The old
  tunnels were deleted, which invalidated the leaked tokens.
- **Admin apps that are reachable through the tunnel** were each tested with unauthenticated
  requests and return 401/403. Their hostnames aren't published in this repo.
- **No Tailscale.** It was used once for an off-site SMB copy, then removed from both hosts in
  November 2026. One less agent with network access on the hypervisors. The hosts use Pi-hole for
  DNS, set through Proxmox (`pvesh set /nodes/<host>/dns`).

## Deployments: GitOps

The repo is the source of truth, and nothing is changed on a host by hand.

| What | Deployed by | Trigger |
|---|---|---|
| Docker stacks in `stacks/` | **Portainer** Git stacks | Polls `main` every 5 minutes |
| Immich (VM) | **Ansible** (`playbooks/immich.yml`) | A push to `main` touching Immich |
| OS packages, accounts, SSH config | **Ansible** | Weekly schedule, or by hand |

**Image versions are pinned** (no `:latest`; CI rejects it), so a deploy is reproducible and every
change is a reviewable diff. **Renovate** turns new releases into pull requests:

- **Low-risk apps** auto-merge once CI passes and the release is 3 days old.
- **Stateful apps** (Vaultwarden, Paperless, Mealie, Immich) always wait for review.
- **Database major versions** are blocked, because they need a migration, not an image bump.

Details: [ci-cd.md](ci-cd.md).

## Configuration management: Ansible

- **A dedicated control node.** Ansible runs on its own LXC with a host-mode Gitea runner.
  - Jobs are started from the Gitea Actions tab, or on a schedule.
  - Its SSH key is generated there and never leaves it. It isn't stored in Gitea.
  - It isn't in any patch group (patching it would kill the job doing the patching). It installs
    its own security updates.
- **Weekly patching** runs one host at a time and stops at the first failure. It's scheduled after
  the nightly PBS backups, so every patch run has a fresh restore point. Proxmox hosts are only
  patched by hand.
- **`known_hosts` is committed**, so Ansible verifies every host's identity instead of trusting
  whatever answers on an IP.

## Access control

| Account | Login | Rights |
|---|---|---|
| personal admin | SSH key, from a password manager's SSH agent (no key files on disk) | `sudo` with a password |
| break-glass | password only, **LAN/VPN only** (`sshd` Match block); name not in this repo | `sudo` with a password |
| `ansible` | the control node's key, accepted only from its IP | passwordless `sudo` |
| `root` | console only (Proxmox shell, VM console, JetKVM) | — |

Root and password SSH logins are off on every host. The hardening playbook:
- refuses to run where the admin account has no key
- simulates logins with `sshd -T -C` before restarting `sshd`
- puts the old config back automatically if any check fails

Web apps use **Authentik** (OIDC) where they support it, with a break-glass local account in each.
Apps with no login of their own (Kiwix) are put behind Authentik's **embedded proxy outpost**: their
public hostname points at Authentik (`:9000`), which matches the hostname to a proxy provider,
requires a login and membership of that app's group, then forwards to the app on the LAN. Apps
with phone or TV clients stay on their own login or OIDC, because those clients can't pass a
browser login page.

**Guest firewall: no bypass on the LAN.** A proxy login only helps if the app can't be reached
around it. The Proxmox firewall is on for skynet's guests (Datacenter on, host policy ACCEPT and
the node firewall off, so the hosts themselves are unfiltered). The survival LXC has its own rules:
incoming DROP, except Kiwix's port from Authentik (and Homepage's status check), the Portainer
agent from the Portainer server, SSH and ping. The rules are enforced on the host, on the
container's virtual network cable, so nothing inside the container can turn them off. Break-glass:
CT 101 → Firewall → Options → Firewall: No.

## Storage

Data lives on separate drives, bind-mounted into the guests. Guest disks (rootfs) live on
Proxmox storage.

| Host | Folder | Holds |
|---|---|---|
| skynet | `/mnt/media` (16 TB HDD) | Movies, TV, audiobooks, downloads, *arr configs (CT 100), read by Plex (CT 103) |
| skynet | `/mnt/nvme1` | Gitea (CT 107), Authentik (CT 108), the Docker CI runner (CT 109), DB dumps |
| skynet | `/mnt/nvme0` | The Kiwix library (CT 101) |
| skynet | `/mnt/nvme2` | Empty (spare) |
| skynet | `/mnt/nvme3` | Proxmox storage `nvme3`: guest disks (CTs 101, 103, 107, 108, VM 502), ISOs, templates |
| little-skynet | `/mnt/main-drive` (4 TB HDD) | Vaultwarden and other household app data (bind-mounted into CT 101) |
| little-skynet | `/mnt/second-drive` (NVMe) | Immich photos (virtiofs into the VM) |
| little-skynet | `/mnt/temp-mnt` (8 TB USB) | The nightly rsync copy. Only root's rsync writes to it |

**Identify drives by UUID or serial, never `/dev/nvmeXn1`.** The kernel's NVMe numbering can
change between boots (it did on skynet in November 2026), and the folder names don't follow it.
fstab uses UUIDs. To match a folder to a physical drive:
`lsblk -o NAME,SIZE,SERIAL,MODEL,UUID,MOUNTPOINTS`.

**A missing drive can't be mistaken for an empty one.** Every data drive is mounted with
`nofail,x-systemd.device-timeout=30s`, so a dead drive doesn't stop the host from booting. The
empty folder under each mount is immutable (`chattr +i`), so nothing can write into it while the
drive is missing. Proxmox's `nvme3` storage has `is_mountpoint yes`, so Proxmox won't put guest
disks into an empty folder, and host-backup refuses to run if a drive isn't mounted. Details and
commands: [hardening.md](hardening.md#drives-and-boot).

**GPUs.** skynet's Quadro P2200 is passed through to Plex (CT 103) for hardware transcoding. The
host driver is built by DKMS for every installed kernel. The NVIDIA libraries inside CT 103 must be
the exact same version as the host driver, or Plex silently falls back to the CPU. The host driver
comes from NVIDIA's `.run` installer, so apt never upgrades it. CT 103's libraries come from
NVIDIA's apt repo, so they're held (`apt-mark hold`) at the host's version. Upgrading the driver
means upgrading both together, on purpose. `patch-hosts`
warns before a reboot if DKMS didn't build the module for the new kernel. little-skynet's Quadro
P620 is unused, and its driver is removed. Details: [gpu.md](gpu.md).

## Backups

| Data | Protection |
|---|---|
| Every LXC and the Immich VM's disk | **Proxmox Backup Server**, nightly (little-skynet 03:00, skynet 03:30), one namespace per host |
| Bind-mounted data PBS's guest backups skip: Gitea/Authentik (`/mnt/nvme1`), the Kiwix library (`/mnt/nvme0`), Immich photos (`/mnt/second-drive`) | **host-backup** (Ansible): nightly to PBS namespace `hosts` with a backup-only token; changed files only, full read on Sundays |
| Each Proxmox host's own config: `/etc`, `/etc/pve` (every guest's config, storage, backup jobs), `/root`, root's crontab | **host-backup**, same run, as separate archives (`etc`, `pve`, `root`, `crontabs`) |
| Vaultwarden, photos, documents (little-skynet `/mnt/main-drive`, Immich) | Also a nightly copy at 01:00 (**rsync-data**, Ansible) to a USB disk and a Raspberry Pi 4, with 30 days of old versions. Vaultwarden's database is copied with `sqlite3 .backup` and integrity-checked |
| Immich database | Immich's built-in daily dumps, plus a `pg_dumpall` before every upgrade |

**Retention:** a PBS prune job per namespace keeps 7 daily, 4 weekly and 6 monthly snapshots; one
daily verify job checks them.

**Not yet done:** a scheduled restore test from PBS, an offsite copy (3-2-1) and a UPS.

## Secrets

- **Never in Git.** CI rejects committed `.env` files, tunnel tokens and private keys.
- **Stack secrets** live in Portainer stack variables. **Password hashes** for the admin accounts
  live in a file on the Ansible control node. **Everything** has a copy in Vaultwarden.
- **History scrubbed:** before this repo was made public, its history was rewritten with
  `git filter-repo` to remove MAC addresses, admin hostnames and a personal email address.

Details: [secrets.md](secrets.md).

## Known trade-offs and next steps

- The Immich database sits on a virtiofs share. Immich recommends local disk. It runs fine, but
  moving it onto the VM disk would also bring it under PBS.
- Flat network: VLANs (management, servers, IoT, guest) need a managed switch.
- Four containers are privileged with full device access (little-skynet CT 100 and 101, skynet
  CT 100 and 102). Converting them to unprivileged is planned. See
  [hardening.md](hardening.md#still-open).
- No offsite backup or UPS yet.
- Alerts reach the phone through ntfy: failed or missing backup runs (Kuma push monitors), failed
  Proxmox/PBS jobs (webhooks), and apps or hosts going down. Kuma itself runs on little-skynet, and
  disk health, disk space and patch runs aren't watched yet. See [monitoring.md](monitoring.md).
