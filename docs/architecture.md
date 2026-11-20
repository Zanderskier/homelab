# Architecture and design decisions

How the homelab is put together, and why. The operational how-tos live next to the code:
[ci-cd.md](ci-cd.md), [secrets.md](secrets.md), [ansible/README.md](../ansible/README.md).

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

## Backups

| Data | Protection |
|---|---|
| Every LXC and the Immich VM's disk | **Proxmox Backup Server**, nightly (skynet 03:00, little-skynet 03:30), one namespace per host |
| Bind-mounted data PBS's guest backups skip: Gitea/Authentik (`/mnt/nvme1`), the Kiwix library (`/mnt/nvme0`), Immich photos (`/mnt/second-drive`) | **host-backup** (Ansible): nightly to PBS namespace `hosts` with a backup-only token; changed files only, full read on Sundays |
| Photos, documents, Immich database | Also critical-data backups to a second disk and a Raspberry Pi 4 |
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
- No offsite backup or UPS yet.
- Monitoring is uptime-only (Uptime Kuma). Alerts for failed patch runs, backups and disk health are
  next.
