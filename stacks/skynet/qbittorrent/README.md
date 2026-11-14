# qBittorrent (PIA VPN) + tracker dynamic seedbox

qBittorrent is a lightweight, open-source BitTorrent client used to manage and automate peer-to-peer file transfers. Provides a web-based management interface, torrent queueing, bandwidth controls, download scheduling, RSS feed support, and remote access. Integrates with media automation tools such as Sonarr and Radarr to handle automated downloads and file acquisition within a self-hosted media environment.
## Deployment (Portainer Git stack)

1. Portainer -> Stacks -> Add stack -> **Repository**
   - URL: the `homelab` repo
   - Reference: `refs/heads/main`, compose path: `stacks/skynet/qbittorrent/compose.yaml`
2. Add environment variables (see `.env.example`): `PIA_USER`, `PIA_PASSWORD`, `PIA_REGION`, `SEEDBOX_SESSION_COOKIE`, optional `SEEDBOX_SYNC_INTERVAL`.
3. Deploy. Secrets live only in Portainer, never in this repo.

### the tracker dynamic seedbox

The `seedbox-ip-sync` sidecar shares the VPN container's network and calls tracker's
`dynamicSeedbox.php` on start and every `SEEDBOX_SYNC_INTERVAL` seconds, so tracker always has the current
PIA exit IP. tracker rotates the token after first use; the rotated cookie is persisted at
`/mnt/media-storage/arr-stack/qbittorrent/seedbox/session.cookies`. To replace the token, update
`SEEDBOX_SESSION_COOKIE` in Portainer, delete that cookie file, and redeploy. Check `seedbox-ip-sync` logs for results.
