# qBittorrent behind a VPN

qBittorrent runs inside the `j4ym0/pia-qbittorrent` image, which connects to Private Internet Access
(PIA) with port forwarding before qBittorrent starts. All of its traffic leaves through the VPN. It's
the download client for the *arr apps on the same host.

## seedbox-ip-sync sidecar

A private tracker accepts seeding only from IPs registered to the account. The VPN's exit IP
changes, so a small `curl` sidecar shares the VPN container's network and calls the tracker's
"dynamic seedbox" endpoint on start and every `SEEDBOX_SYNC_INTERVAL` seconds. Because it uses the
VPN's network namespace, the tracker sees the VPN IP, not the home IP.

The sidecar saves any cookie the tracker sends back in
`/mnt/media-storage/arr-stack/qbittorrent/seedbox/session.cookies` and reuses it. If the saved cookie
is missing or rejected (anything but the hourly rate limit), it falls back to `SEEDBOX_SESSION_COOKIE`.
The variable may be the bare token or `mam_id=<token>`. To replace the session, update the variable
in Portainer, delete that file, and redeploy. Results are in the `seedbox-ip-sync` logs. Each error
line is followed by a `Fix:` line.

Create the session on the tracker's Security page as **ASN-locked**, with the **VPN's exit IP** (shown
in the sidecar logs, not your browser's IP), and allow it to set the dynamic seedbox. PIA servers in
one region can sit on different ASNs. If the logs show `ASN mismatch` after a reconnect, add that IP's
ASN to the session (Manage Session) instead of making a new one. Redeploy at most once an hour: the
tracker allows one IP change per hour and answers `429` otherwise.

## Deployment (Portainer Git stack)

1. Portainer → Stacks → Add stack → **Repository**, compose path
   `stacks/skynet/qbittorrent/compose.yaml`.
2. Environment variables: everything in `.env.example`.
3. The image version is **locked on purpose** (Renovate ignores it, see `renovate.json`). Change
   the tag by hand after checking the release.
