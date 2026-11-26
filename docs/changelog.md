# Changelog

Notable changes to the lab, newest first: what changed, how, and what it fixed. Details live in
the linked pages; small updates (Renovate bumps) are in the Git history.

## 2026-11-24 – 2026-11-25: hardening, patching, alerting

It started as disaster-recovery discovery (step 2: find hand-made host config) and turned into
fixing what the discovery found: `777` permissions everywhere, drives that could block a boot,
host config in no backup, and nothing that alerted on a failure.

### Permissions ([hardening.md](hardening.md))

- **`/root` on both hosts** was `777` (skynet) or owned by the admin account (little-skynet),
  including a script root's cron ran nightly. Now `root:root 700`, credential files `600`.
- **Media drive (skynet `/mnt/media`):** 2899 world-writable items. One shared group (`smbshare`,
  1001) for every writer: folders `2775` (setgid), files `664`, app configs `2770`, and a default
  ACL so new files stay group-writable whatever umask an app uses. The writers were changed in
  their compose files (`PGID 1001`, `UMASK 002`, `user: 1000:1001`) and Samba got
  `force group` + masks. **How:** saved the old permissions with `getfacl -R`, stopped the apps,
  fixed ownership on disk, then merged the compose changes (Portainer redeploys on merge, so the
  order matters). Tested with a download, imports, Windows SMB and Plex.
- **Per-guest bind mounts:** Gitea, Authentik and the CI runner each mounted the whole
  `/mnt/nvme1`. Now each mounts only its own folder (`pct set ... -mpN`); the paths inside the
  containers didn't change.
- **Backup disk (little-skynet `/mnt/temp-mnt`)** could be written from Windows and from a
  container. The SMB share is read-only, the container mount is gone, only root's rsync writes.
- **Executables on the media drive** (one malware `.scr`, seven RARBG `.exe` files) deleted with
  `find ... -print -delete`; qBittorrent now refuses those file types.
- **Secrets in a Proxmox Notes field** moved to Vaultwarden and rotated.

### Drives and boot ([hardening.md](hardening.md#drives-and-boot))

- **`nofail,x-systemd.device-timeout=30s`** on every data drive, so a dead drive can't stop a boot.
- **Immutable mount points** (`chattr +i`, done through `mount --bind / /run/rootview` with no
  downtime), so nothing writes into an empty folder while its drive is missing. This found 731 old
  config files hidden under skynet's `/mnt/media`, archived and deleted.
- **`is_mountpoint yes`** on the Proxmox directory storage on a data drive.
- **Tested** with real reboots of both hosts after patching.
- **Tailscale removed** from both hosts and a container; DNS set through `pvesh`.

### Backups

- **Host config into PBS:** `host-backup` now also sends `/etc`, `/etc/pve` (its own archive:
  pmxcfs is a separate filesystem the client won't cross), `/root` and root's crontab.
- **`rsync-data` into Ansible:** the hand-made `/root/rsync-data.sh` + cron line became
  `playbooks/rsync-data.yml`: the same jobs from host_vars, a systemd timer, and a fix for the
  Pi's automount (the autofs placeholder counted as "mounted" even with the Pi off).
- **Backup times** in the docs were swapped (little-skynet 03:00, skynet 03:30) and are fixed.

### Patching and the GPU ([gpu.md](gpu.md))

- **All three Proxmox machines patched and rebooted** (both PVE hosts on kernel 7.0.14-30, PBS
  on 6.8.12-43). PBS is still 3.4: the upgrade to 4 is on the roadmap.
- **Plex had been transcoding on the CPU since 2026-11-21:** CT 103's NVIDIA libraries (from
  apt) had moved to 580.196 while the host driver (from NVIDIA's `.run` installer) stayed at
  580.178. **How it was fixed:** found how each side is installed, simulated the downgrade
  (`apt-get install -s`), downgraded to the host's version, `apt-mark hold`. Plex shows
  `Transcode (hw)` again.
- **`patch-hosts` now checks DKMS** built the driver for the new kernel and says "DO NOT REBOOT"
  if not. Its read-only tasks also run in dry runs now.
- **little-skynet's unused NVIDIA driver** (25 leftover packages, a failing unit) purged.

### Monitoring and alerts ([monitoring.md](monitoring.md))

- **ntfy** for phone push notifications, on the public server with a random topic kept as a secret.
- **Uptime Kuma push monitors** for `rsync-data` and `host-backup` (per host): each run reports
  `up` or `down`, and 25 hours of silence alerts too (a dead man's switch). `host-backup` reports
  from an `EXIT` trap, so a missing drive is reported as well.
- **Proxmox VE and PBS** send failed jobs to ntfy through a webhook (topic as a webhook secret,
  title only, errors only).
- **Uptime Kuma** checks every app and host (health endpoints, a DNS check of Pi-hole, a TCP check
  of the Pi's SMB port, one public URL through the tunnel), with 2 retries.
- **`health-check`:** a 5-minute check runner with one push monitor per check. The first check is
  Plex's GPU, which alerts after two failures in a row.

### Repository

- **Branch → PR → merge** for every change, written up in [ci-cd.md](ci-cd.md#making-a-change-branch--pr--merge),
  including how to recover when work lands on `main` by mistake (revert, then rebuild the branch
  with a cherry-pick, which happened once).
- **Cleanup:** merged branches deleted, old stashes dropped, `fetch.prune` turned on.
- **New docs:** [hardening.md](hardening.md), [gpu.md](gpu.md), [monitoring.md](monitoring.md),
  [disaster-recovery/README.md](disaster-recovery/README.md) (runbook outline), this changelog.

### Next

Disaster-recovery restore tests, starting with restoring single files from the host-backup
archives into a scratch folder.
