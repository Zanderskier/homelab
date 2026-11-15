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

LAN `192.168.50.0/24`, every address below is a DHCP reservation on the router. Public hostnames
are on `failsafe.work`, all served through the single Cloudflare tunnel **Skynet-homelab**
(`7dbb7570-…`), so no ports are forwarded.

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
| Gitea Actions runner | gitea-runner | 192.168.50.90 |
| Immich (VM) | Immich | 192.168.50.106 |
| Gitea | gittea-repo | 192.168.50.124 |
| JetKVM #1 | Jet-KVM | 192.168.50.150 |
| Authentik | Authentik | 192.168.50.151 |
| Foundry VTT | Foundry-dnd | 192.168.50.159 |
| Living room printer | Living-Room-Printer | 192.168.50.166 |
| Arr stack (media apps) | Arr-Stack | 192.168.50.199 |
| Proxmox host: little-skynet | Little-Skynet | 192.168.50.220 |
| File Browser | File-Browser | 192.168.50.246 |

### Services

| Service | Runs on | Internal URL | Public hostname |
|---|---|---|---|
| Portainer | Portainer-Lsky | https://192.168.50.81:9443 | (admin, not published) |
| Uptime Kuma | Portainer-Lsky | http://192.168.50.81:3001 | (admin, not published) |
| Paperless-ngx | Portainer-Lsky | http://192.168.50.81:8010 | [paperless.failsafe.work](https://paperless.failsafe.work) |
| Vaultwarden | Portainer-Lsky | http://192.168.50.81:8123 | [vaultwarden.failsafe.work](https://vaultwarden.failsafe.work) |
| Mealie | Portainer-Lsky | http://192.168.50.81:9925 | [mealie.failsafe.work](https://mealie.failsafe.work) |
| Homepage, Tautulli | Portainer-Lsky | 192.168.50.81 | — (LAN only) |
| Plex | Video-Captin | http://192.168.50.88:32400 | [plex.failsafe.work](https://plex.failsafe.work) |
| Immich | Immich | http://192.168.50.106:2283 | [immich.failsafe.work](https://immich.failsafe.work) |
| Gitea | gittea-repo | http://192.168.50.124:3000 | [gitea.failsafe.work](https://gitea.failsafe.work) |
| Gitea runner | gitea-runner | 192.168.50.90 | — |
| Authentik | Authentik | http://192.168.50.151:9000 | [authentik.failsafe.work](https://authentik.failsafe.work) |
| Foundry VTT | Foundry-dnd | http://192.168.50.3:30000 ⚠️ | [dnd.failsafe.work](https://dnd.failsafe.work) |
| Foundry proxy | Foundry-dnd | http://192.168.50.3:3000 ⚠️ | [dnd-proxy.failsafe.work](https://dnd-proxy.failsafe.work) |
| Sonarr | Arr-Stack | http://192.168.50.199:8989 | (admin, not published) |
| Radarr | Arr-Stack | http://192.168.50.199:7878 | (admin, not published) |
| Prowlarr | Arr-Stack | http://192.168.50.199:9696 | (admin, not published) |
| SABnzbd | Arr-Stack | http://192.168.50.199:8080 | (admin, not published) |
| qBittorrent | Arr-Stack | http://192.168.50.199:8888 | (admin, not published) |
| Overseerr | Arr-Stack | http://192.168.50.199:5055 | [overseerr.failsafe.work](https://overseerr.failsafe.work) |
| Requestrr | Arr-Stack | http://192.168.50.199:4545 | (admin, not published) |
| Audiobookshelf | Arr-Stack | http://192.168.50.199:13378 | [audiobookshelf.failsafe.work](https://audiobookshelf.failsafe.work) |
| File Browser | File-Browser | http://192.168.50.246:8080 | (admin, not published) |
| Pi-hole | DNS-Skynet | http://192.168.50.2/admin | — |
| Proxmox VE (skynet) | Skynet | https://192.168.50.8:8006 | — (`skynet.failsafe.work` A record → LAN IP) |
| Proxmox VE (little-skynet) | Little-Skynet | https://192.168.50.220:8006 | — (`little-skynet.failsafe.work` A record → LAN IP) |
| Proxmox Backup Server | PBS | https://192.168.50.76:8007 | — |
| JetKVM | Jet-KVM / Jet-KVM2 | http://192.168.50.150 / .18 | — |

⚠️ The tunnel routes `dnd` and `dnd-proxy` to `192.168.50.3`, but the Foundry-dnd reservation is
`192.168.50.159`. One of the two needs updating.

**Stale DNS records** (point at tunnels that no longer exist, safe to delete): `failsafe.work`
(apex, tunnel `5176bf9c-…`) and `(admin hostname, not published)` (tunnel `1385d5a8-…`).

## Layout

```
stacks/
  shared/        stacks deployed on more than one host
    cloudflared/   single Cloudflare tunnel, one replica per host
  skynet/
    arr-stack/  audiobookshelf/  foundry-vtt/  gitea-runner/  qbittorrent/
  little-skynet/
    homepage/  mealie/  paperless-ngx/  tautulli/  uptime-kuma/  vaultwarden/
.gitea/workflows/
  lint.yml        validates every compose file, blocks :latest tags and committed secrets
  renovate.yml    runs Renovate every 4 hours
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
- [ ] Renovate + Gitea Actions: update PRs, CI lint, tiered auto-merge ([docs/ci-cd.md](docs/ci-cd.md))
- [ ] Ansible: OS patching for all LXCs/VMs/Pis, Proxmox/PBS updates, Immich, Portainer
- [ ] Monitoring and alerting (metrics, SMART, backup failures → ntfy)
- [ ] Managed switch + VLANs (mgmt / servers / trusted / IoT / guest)
- [ ] UPS, offsite backups (budget permitting)
