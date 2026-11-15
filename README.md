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
