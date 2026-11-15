# homelab

Infrastructure-as-code for my homelab: every Docker stack, and (soon) the Ansible that patches the
hosts, lives in this one repo. Portainer deploys stacks straight from Git (GitOps), so the repo is
the source of truth: change a file, merge, and the host converges.

## Hardware

| Host | Hardware | Role |
|---|---|---|
| **skynet** | Dell Precision 5810, 14C/28T, 64 GB ECC, Quadro P2200, 16 TB media HDD, 3x 2 TB NVMe | Proxmox VE 9: media (Plex, *arr), Gitea, Authentik, Foundry |
| **little-skynet** | Dell OptiPlex 7050, 16 GB, 4 TB HDD, 2 TB NVMe (Immich) | Proxmox VE 9: Portainer (control plane), household apps, Immich, cloudflared |
| **pbs** | Toshiba Qosmio (2013), 4C/8T, 12 GB, 4 TB USB HDD | Proxmox Backup Server for all LXCs/VMs |
| **pi2** | Raspberry Pi 2 | Pi-hole + Unbound (recursive DNS, ad blocking) |
| **pi4** | Raspberry Pi 4, 2 TB SSD | Critical-data backup target |
| — | 8 TB HDD dock on little-skynet | Critical-data backup target |
| — | 2x JetKVM | Out-of-band console for both Proxmox hosts |
| — | ASUS RT-AX1800S | Router, DHCP reservations, OpenVPN remote access |

## Network

LAN `192.168.50.0/24`, every address below is a DHCP reservation on the router. Remote access goes
through a single Cloudflare tunnel (outbound only, so no ports are forwarded) or the OpenVPN server
on the router.

### Devices

| Device | Hostname | IP |
|---|---|---|
| Pi-hole + Unbound (Pi 2) | DNS-Skynet | 192.168.50.2 |
| Proxmox host: skynet | Skynet | 192.168.50.8 |
| JetKVM #2 | Jet-KVM2 | 192.168.50.18 |
| cloudflared | CloudFlare | 192.168.50.27 |
| Critical-data backup (Pi 4) | Skynet-Data-recover | 192.168.50.75 |
| Proxmox Backup Server | PBS | 192.168.50.76 |
| Portainer + little-skynet stacks | Portainer-Lsky | 192.168.50.81 |
| Plex | Video-Captin | 192.168.50.88 |
| Gitea Actions runner (lint, Renovate) | gitea-runner | 192.168.50.90 |
| Immich (VM) | Immich | 192.168.50.106 |
| Gitea | gittea-repo | 192.168.50.124 |
| Ansible control node | Ansible | 192.168.50.129 |
| JetKVM #1 | Jet-KVM | 192.168.50.150 |
| Authentik | Authentik | 192.168.50.151 |
| Foundry VTT | Foundry-dnd | 192.168.50.159 |
| Living room printer | Living-Room-Printer | 192.168.50.166 |
| Arr stack (media apps) | Arr-Stack | 192.168.50.199 |
| Proxmox host: little-skynet | Little-Skynet | 192.168.50.220 |
| File Browser | File-Browser | 192.168.50.246 |

### Services

**Exposure:** *Public* = published through the tunnel for users and their apps. *Admin* = also
reachable through the tunnel, but the hostname is deliberately not listed here, and the app's own
login is required. *LAN/VPN* = not exposed at all.

| Service | Runs on | Internal URL | Exposure |
|---|---|---|---|
| Plex | Video-Captin | http://192.168.50.88:32400 | Public |
| Immich | Immich | http://192.168.50.106:2283 | Public |
| Vaultwarden | Portainer-Lsky | http://192.168.50.81:8123 | Public |
| Paperless-ngx | Portainer-Lsky | http://192.168.50.81:8010 | Public |
| Mealie | Portainer-Lsky | http://192.168.50.81:9925 | Public |
| Audiobookshelf | Arr-Stack | http://192.168.50.199:13378 | Public |
| Overseerr | Arr-Stack | http://192.168.50.199:5055 | Public |
| Gitea | gittea-repo | http://192.168.50.124:3000 | Public |
| Authentik (SSO) | Authentik | http://192.168.50.151:9000 | Public |
| Foundry VTT + D&D Beyond proxy | Foundry-dnd | :30000 / :3000 | Public |
| Portainer | Portainer-Lsky | https://192.168.50.81:9443 | Admin |
| Uptime Kuma | Portainer-Lsky | http://192.168.50.81:3001 | Admin |
| Sonarr / Radarr / Prowlarr | Arr-Stack | http://192.168.50.199:8989 / 7878 / 9696 | Admin |
| SABnzbd / qBittorrent | Arr-Stack | http://192.168.50.199:8080 / 8888 | Admin |
| Requestrr | Arr-Stack | http://192.168.50.199:4545 | Admin |
| File Browser | File-Browser | http://192.168.50.246:8080 | Admin |
| Homepage, Tautulli | Portainer-Lsky | http://192.168.50.81:4000 / 8181 | LAN/VPN |
| Pi-hole | DNS-Skynet | http://192.168.50.2/admin | LAN/VPN |
| Proxmox VE | Skynet / Little-Skynet | https://192.168.50.8:8006 / .220:8006 | LAN/VPN |
| Proxmox Backup Server | PBS | https://192.168.50.76:8007 | LAN/VPN |
| JetKVM (out-of-band) | Jet-KVM / Jet-KVM2 | http://192.168.50.150 / .18 | LAN/VPN |

Every admin app was verified to reject unauthenticated requests through the tunnel (401/403).

## Layout

```
stacks/
  shared/        stacks deployed on more than one host
    cloudflared/   single Cloudflare tunnel, one replica per host
  skynet/
    arr-stack/  audiobookshelf/  foundry-vtt/  gitea-runner/  qbittorrent/
  little-skynet/
    homepage/  mealie/  paperless-ngx/  tautulli/  uptime-kuma/  vaultwarden/
ansible/          OS updates for every machine, run from the Ansible LXC (see ansible/README.md)
.gitea/workflows/
  lint.yml        validates compose files + playbooks, blocks :latest tags and committed secrets
  renovate.yml    runs Renovate every 4 hours
  ansible.yml     weekly OS patching (Sunday 03:00), or any playbook on demand
renovate.json     update policy: what auto-merges and what waits for review
docs/
  ci-cd.md        how updates flow from a new release to a running container
  cloudflare.md   tunnel + Zero Trust Access design and migration
  migration.md    moving Portainer from the old per-app repos to this repo
  secrets.md      where secrets live and how to rotate them
```

Each stack directory has a `compose.yaml` and, if it needs secrets, a `.env.example` listing the
variables to set in Portainer.

## Deploying a stack (Portainer GitOps)

1. Portainer → select the environment (host) → **Stacks → Add stack → Repository**
2. Repository URL: this repo. Use the **internal** Gitea URL (e.g. `http://<gitea-ip>:3000/...`) so
   deploys don't depend on Cloudflare, with a Gitea access token that only has `read:repository`.
3. Reference `refs/heads/main`, compose path `stacks/<host>/<app>/compose.yaml`.
4. Environment variables: everything in that stack's `.env.example`.
5. Enable **GitOps updates → Polling** (5m) or a webhook from Gitea. Merging to `main` redeploys.

## Conventions

- **No secrets in Git.** Values come from Portainer stack variables, pulled into compose with
  `${VAR}` interpolation or bare `- KEY` pass-through. Git-deployed stacks don't get a `stack.env`
  file, so `env_file: stack.env` doesn't work here. `${VAR:?message}` makes a deploy fail loudly if a
  required secret is missing.
- `restart: unless-stopped` everywhere, `TZ` defaults to `America/Los_Angeles`.
- Bind mounts for app data (`/main/...` on little-skynet, `/mnt/media-storage/...` on skynet) so data
  survives stack renames; named volumes are pinned with `external: true`.
- Unique `container_name`s (no generic `postgres`).

## Not in the repo yet

Gitea, Authentik, Immich (VM), File Browser, Plex (helper-script LXC), Pi-hole, Ollama.

## Roadmap

- [x] Merge per-app repos into one repo; remove secrets from compose files
- [x] Single Cloudflare tunnel with published application routes for every hostname
- [x] Delete old tunnels; every exposed admin app verified to require login
- [x] Pin every image to an exact version
- [x] Renovate + Gitea Actions: update PRs, CI lint, tiered auto-merge ([docs/ci-cd.md](docs/ci-cd.md))
- [ ] Ansible: OS patching for all LXCs/VMs/Pis + Proxmox/PBS ([ansible/README.md](ansible/README.md))
- [ ] Ansible: Immich deploys and updates from this repo
- [ ] Ansible: Portainer server/agent updates
- [ ] Monitoring and alerting (metrics, SMART, backup failures → ntfy)
- [ ] Managed switch + VLANs (mgmt / servers / trusted / IoT / guest)
- [ ] UPS, offsite backups (budget permitting)
