# Disaster recovery runbook

What to do when something breaks, from the smallest failure to the worst. **Restore first, from
Proxmox Backup Server. Rebuild from this repo only when there is nothing to restore.**

Status: outline. Sections marked **TODO** still need a tested procedure. Each scenario gets
"tested on <date>" once it has been done for real.

## Before anything else

1. **Passwords offline.** Vaultwarden runs in the lab, so it may be down. The Bitwarden apps keep an
   offline copy (unlock works without the server). If no device has it: the encrypted vault export
   on the USB sticks in the safe, imported into a fresh Bitwarden client.
2. **Write down what you see** before changing anything: which host, which guest, the error, the
   time. Take a photo of the console.
3. **Don't make it worse.** Never run `fsck`, `mkfs`, `pvecm` or a restore that overwrites onto a
   disk you're not sure about. Restore to a **new** guest ID first (e.g. 9xx), check it, then swap.

## Recovery order (tiers)

| Tier | What | Why first |
|---|---|---|
| 0 | Offline passwords · DNS (Pi-hole, 192.168.50.2) · PBS reachable (192.168.50.76:8007) | Nothing else can be restored without them |
| 1 | Vaultwarden (little-skynet CT 101) · Immich (little-skynet VM 103) · File Browser (little-skynet CT 100) | Needed the same day. All on little-skynet, so **little-skynet is the critical host** |
| 2 | Gitea (CT 107) · Ansible (CT 110) · cloudflared (little-skynet CT 102) · Portainer (little-skynet CT 101) | Brings back GitOps, remote access and automation |
| 3 | Everything else (Plex, *arr, Authentik, Kiwix, runners) | Can wait days |

## Where things are backed up

| What | Where | How to get it back |
|---|---|---|
| Every guest's disk | PBS, nightly (little-skynet 03:00, skynet 03:30), namespace per host | Proxmox UI → storage `PBS` → Backups → Restore |
| Bind-mounted data (`/mnt/nvme1`, `/mnt/nvme0`, `/mnt/second-drive`) | PBS namespace `hosts`, `host/<host>`, nightly | `proxmox-backup-client restore`, see [ansible/README.md](../../ansible/README.md#host-folder-backups-host-backup) |
| Host config (`/etc`, `/etc/pve`, `/root`, crontabs) | Same snapshot: `etc`, `pve`, `root`, `crontabs` archives | Same. Single files: PBS UI → snapshot → archive → Download |
| Vaultwarden, documents, photos (little-skynet) | `/mnt/temp-mnt` (USB, ext4) and the Pi 4 (CIFS), 01:00 nightly | Copy back with rsync. **Use the USB copy first**: the Pi copy loses Linux owners |
| Gitea DB | `/mnt/nvme1/db-dumps/` (in the `nvme1` archive) | `gunzip -c ... \| psql -U gitea` into a fresh `gitea-db` |
| Immich DB | Immich's nightly dumps in `immich/library/backups` (in little-skynet's `immich` archive) | Immich's restore procedure |
| This repo | Gitea, mirrored to GitHub | Clone from GitHub if Gitea is gone |
| `/mnt/media` (movies, TV) | **Not backed up** (accepted risk) | Re-download |

## Scenario 1: one data drive fails

Signs: the host boots, but a guest can't find its data; `findmnt /mnt/<drive>` prints nothing;
host-backup logs `ERROR: /mnt/... is not a mounted drive`.

1. Confirm: `findmnt /mnt/<drive>`, `lsblk -o NAME,SIZE,SERIAL,MODEL,UUID,MOUNTPOINTS`,
   `journalctl -b | grep -i -E 'nvme|sd[a-z]|I/O error'`. The empty folder is immutable, so nothing
   has been written into it.
2. Stop the guests that use it (`grep -l /mnt/<drive> /etc/pve/lxc/*.conf`).
3. Replace the drive, partition and format it (ext4), and put its **new UUID** in fstab, keeping
   `nofail,x-systemd.device-timeout=30s`. Then `systemctl daemon-reload && mount /mnt/<drive>`.
4. Restore the data from host-backup (bind-mount drives) or the rsync copy (little-skynet), then
   fix ownership (see [hardening.md](../hardening.md)).
5. Start the guests and check the apps.

TODO: test on the spare `/mnt/nvme2`.

## Scenario 2: one guest is broken

Signs: an app is down and the container or VM won't start, or its data is damaged.

1. Check whether it's the guest or its bind-mounted drive (scenario 1).
2. Restore the newest good backup **to a new ID**: Proxmox UI → `PBS` storage → Backups → pick the
   guest → Restore → VM/CT ID `9xx`, "Start after restore" off.
3. Before starting it, check its config (`pct config 9xx`): the same bind mounts as the original mean
   both would use the same data. Remove or change them if the original is still running.
4. Stop the original, start the restore, test. When it's good: delete the original and restore
   again to the original ID (or change the ID), so DHCP reservations, backups and Ansible still
   match.

Tested 2026-11-23: CT 101 restored as CT 901 (26 GB in 6 min), containers started.

## Scenario 3: one Proxmox host is lost (PBS is fine)

Signs: the host won't boot, or its boot disk is gone. The data drives may be fine.

1. **Reinstall Proxmox VE** on the boot disk: the same hostname, IP (192.168.50.8 or .220) and
   version. TODO: where the installer ISO lives when the lab is down.
2. **Get the old config back** from host-backup (the `pve` and `etc` archives). Restore them to a
   folder, **don't copy them over the new install**:
   `proxmox-backup-client restore --ns hosts host/<host>/<time> pve.mpxar /root/old-pve`.
   TODO: proxmox-backup-client on a fresh host needs the PBS fingerprint and token. Write down how.
3. **Data drives:** put the old fstab lines back (`/root/old-etc/fstab`), mount, and re-apply the
   immutable folders (see [hardening.md](../hardening.md#drives-and-boot)).
4. **Storage:** re-create the entries from the old `storage.cfg` (PBS storage with its fingerprint,
   directory storages with `is_mountpoint yes`).
5. **Guests:** restore each from PBS, tier by tier, **to their original IDs**. Their bind mounts come
   back with the config.
6. **Host config** that isn't in a guest or in Ansible: Samba (`/etc/samba/smb.conf`), root's
   crontab, scripts in `/root`, the NVIDIA driver on skynet (must match Plex's CT, see
   [gpu.md](../gpu.md)). Take each from the old archives.
7. **Ansible:** re-run `users`, `harden-ssh`, `host-backup`, and on little-skynet `rsync-data`, on
   skynet `health-check` (and the runner hosts). Update `known_hosts` for the new host key. The
   push monitors in Uptime Kuma turn green once the jobs run again.

TODO: the order of steps 4–6 for skynet, where Gitea and the Ansible runner are themselves guests.

## Scenario 4: both hosts lost (PBS is fine)

1. Tier 0: offline passwords, DNS (Pi-hole runs on the Pi, so it should be up), PBS reachable.
2. **little-skynet first** (scenario 3): it holds every tier 1 service.
3. Then skynet. Gitea and Ansible come back from PBS, so the repo and automation return with them.
   If Gitea's restore fails: clone this repo from GitHub.
4. Re-point anything that broke: Portainer agents, the Cloudflare tunnel (CT 102), runners.

TODO: a full timed run.

## Scenario 5: the house is lost (PBS too)

Today there is **no off-site copy**, so this scenario can only rebuild, not restore:

- The repo (GitHub mirror) rebuilds the stacks, Ansible and docs.
- Passwords: the encrypted export on the USB sticks, if they survived (they're in the house).
- Photos and documents: **lost** unless they're somewhere else.

Fix before this runbook can cover it: an encrypted off-site copy of PBS (or at least Vaultwarden,
Immich and Paperless). The host-backup archives contain secrets, so an off-site copy must be
encrypted.

## How you'd find out

Most failures announce themselves on the phone (ntfy): a failed or missing backup run, a failed
Proxmox/PBS job, an app or host down, Plex's GPU. See [monitoring.md](../monitoring.md). If
**little-skynet** is down, Uptime Kuma is down with it and nothing alerts: a silent phone plus
unreachable apps means start with little-skynet.

## After any recovery

- Run host-backup and a PBS backup of the restored guests, then check they succeeded.
- Note what went wrong and what was missing in this page, with the date.
