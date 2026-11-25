# Host hardening: permissions, drives and boot

The permission and safety changes made to both Proxmox hosts in November 2026, with the reasons
and the commands to check them. Most of this is host config that isn't in Ansible yet, so this
page is the record of how the hosts are meant to look. The config itself is backed up nightly by
host-backup (`etc`, `pve`, `root` and `crontabs` archives, see
[ansible/README.md](../ansible/README.md#host-folder-backups-host-backup)).

**Starting point.** After a migration, both hosts had `777` almost everywhere: `/root`, the SMB
password files, 2899 items on the media drive. Every account and every service could read or
change everything, including files that root runs. The rule now: **nothing is world-writable,
each writer gets exactly the folders it needs, and secrets are readable by root only.**

Quick check, on either host (expect `0`, or no output):

```bash
for d in /root /mnt/*; do mountpoint -q "$d" || [ "$d" = /root ] || continue
  printf '%-22s %s\n' "$d" "$(find "$d" -xdev -perm -0002 ! -type l 2>/dev/null | wc -l)"; done
```

## Root's home and credential files (both hosts)

| Path | Was | Now | Why |
|---|---|---|---|
| `/root` | `777` (skynet), owned by `alex` (little-skynet) | `root:root 700`, nothing group/world-writable | Anyone who could edit root's `.bashrc` would get root the next time root logged in |
| `/root/.ssh` | `777` | `700` | Holds root's authorized keys |
| `/root/.smbcredentials` | `777` / `alex 755` | `root:root 600` | The SMB share's username and password. Mounts run as root, so nothing else needs it |
| `/root/rsync-data.sh` (little-skynet) | owned by `alex` | `root:root`, not group/world-writable | Root's cron ran it nightly: whoever could edit it became root at 01:00. Now replaced by `/usr/local/sbin/rsync-data` (Ansible, `root:root 0750`) |

```bash
chown -R root:root /root && chmod 700 /root && chmod -R go-w /root
chmod 700 /root/.ssh && chmod 600 /root/.smbcredentials
stat -c '%A %U:%G %n' /root /root/.ssh /root/.smbcredentials    # drwx------ / drwx------ / -rw-------
```

**Rule for hand-made scripts:** anything root runs (cron, systemd) is owned by root and writable
only by root. Credential files are `600` and never executable.

## The shared media drive (skynet `/mnt/media`)

Several writers share this drive: qBittorrent, the *arr apps, Audiobookshelf, the seedbox sidecar,
and Windows over SMB. Plex reads it from an unprivileged container. Instead of `777`, everyone
writes as **user `1000`, group `smbshare` (`1001`)**:

| Item | Setting | What it does |
|---|---|---|
| Owner | `1000:1001` on everything | One owner and group, including old `uid 700` and root leftovers |
| Folders | `2775` | The setgid bit (`2`) makes new files inherit the `smbshare` group, even from apps that ignore their GID setting |
| Files | `664` | Group-writable, world-readable (Plex reads through "other"). Videos don't need the execute bit |
| App configs (`arr-stack/`, `audio-book-shelf/config/`) | folders `2770`, "other" gets nothing | They hold API keys and the seedbox cookie. Plex doesn't need them |
| Default ACL on every folder | `u::rwx,g::rwx,o::rx` (configs: `o::---`) | New files stay group-writable **whatever umask the app uses**. This is what keeps it fixed |

How each writer is set up (all in this repo, so Portainer enforces it):

- **arr-stack:** `PGID: 1001` and `UMASK: "002"` for every app (`x-common-env` in
  [compose.yaml](../stacks/skynet/arr-stack/compose.yaml)). Radarr's old `UMASK 022` is gone.
- **qBittorrent:** `UID=1000`, `GID=1001`, `UMASK=002`.
  **seedbox-ip-sync:** `user: "1000:1001"`, so it no longer runs as root.
- **Audiobookshelf:** `user: "1000:1001"`. Without it, it runs as root and its files are root's.
- **Samba `[skynet-media]`:** files from Windows get the same group and modes:

  ```ini
     force group = smbshare
     create mask = 0664
     directory mask = 2775
     inherit acls = yes
  ```

  Apply with `testparm -s >/dev/null && systemctl reload smbd`.

The one-time fix (stop the apps first). This changes only metadata, so it takes minutes, not
hours:

```bash
M=/mnt/media
getfacl -R -p "$M" > /root/media-perms-before.acl     # undo: setfacl --restore=/root/media-perms-before.acl
skip() { find "$M" -xdev -path "$M/lost+found" -prune -o "$@"; }
skip -exec chown -h 1000:1001 {} +
skip -type d -exec chmod 2775 {} +
find "$M" -xdev \( -path "$M/lost+found" -o -path "$M/arr-stack" \) -prune -o -type f -exec chmod 664 {} +
chmod -R u+rwX,g+rwX,o-rwx "$M/arr-stack" "$M/audio-book-shelf/config"
find "$M/arr-stack" "$M/audio-book-shelf/config" -type d -exec chmod 2770 {} +
skip -type d -exec setfacl -d -m u::rwx,g::rwx,o::rx {} +
find "$M/arr-stack" "$M/audio-book-shelf/config" -type d -exec setfacl -d -m o::--- {} +
find "$M" -xdev -perm -0002 ! -type l | wc -l          # 0 (was 2899)
```

**Order matters when changing a writer's UID/GID:** fix ownership on disk first, then merge the
compose change. Portainer redeploys within 5 minutes of the merge, and an app that starts as the
new user on files it can't write will fail.

Tested after the change: a qBittorrent download (`-rw-rw-r-- 1000 1001`), a Sonarr and a Radarr
import, an Audiobookshelf scan, creating/editing/deleting files from Windows, and Plex playback.

**qBittorrent also refuses dangerous file types** (Options → Downloads → Excluded file names, one
per line): `*.exe`, `*.scr`, `*.bat`, `*.cmd`, `*.lnk`, `*.msi`, `*.zipx`. A "video" that is
really an `.exe` is malware, and the drive is shared to Windows over SMB.

## skynet `/mnt/nvme1`: one folder per guest

Gitea (CT 107), Authentik (CT 108) and the CI runner (CT 109) keep their data here. Each container
used to bind-mount the **whole drive**, so a compromised CI job could read Gitea's and Authentik's
data. Now each mounts only its own folder (the path inside the container didn't change):

| CT | Host folder | Inside the CT |
|---|---|---|
| 107 Gitea | `/mnt/nvme1/gittea` | `/mnt/nvme1/gittea` (`/root/gitea` is a symlink to it) |
| 108 Authentik | `/mnt/nvme1/authentik` | unchanged |
| 109 gitea-runner | `/mnt/nvme1/gitea-runner` | unchanged |

Changed with `pct set <ct> -mpN <host path>,mp=<ct path>` and then `pct reboot <ct>`. The top of
the drive went from `777` to `755` and `lost+found` to `700`. Each app's folder was already owned
by its container's mapped root (`100000`).

## little-skynet: the backup disk is independent

`/mnt/temp-mnt` (8 TB USB) holds the nightly copy of Vaultwarden, photos and documents. A backup
that production can write to isn't a backup: ransomware on the PC, or a bad container, could
encrypt or delete it, `_versions` folders included.

- **The SMB share `Little-skynet-backup` is `read only = yes`.** You can still browse and restore
  from Windows.
- **No container mounts it.** CT 101 had it as `mp1`, unused, and it's removed.
- **Only root's rsync writes to it:** `/mnt/temp-mnt` is `root:root 755`, nothing world-writable.
- **The copy runs at 01:00** from `rsync-data.timer`, installed by Ansible
  (`playbooks/rsync-data.yml`, see [ansible/README.md](../ansible/README.md#critical-data-copies-rsync-data)).
  It finishes before the 02:45 host-backup and the 03:00 PBS job. Each run ends with a `RESULT`
  line in `journalctl -u rsync-data.service`.

## Drives and boot

Problem: if a data drive dies or isn't plugged in, two bad things can happen. Without `nofail` the
host stops booting (emergency shell, no guests). With `nofail` it boots, but the mount folder is
just an empty folder on the boot disk, and apps, rsync or Proxmox write into it as if it were the
drive. Both hosts now handle this:

1. **fstab:** every data drive has `defaults,nofail,x-systemd.device-timeout=30s`, so the host
   boots without it after 30 s. Backups of the old files: `/root/fstab.bak`. Drives should be
   mounted by UUID: `grep -E '^/dev/(sd|nvme)' /etc/fstab` should print nothing.
2. **The empty folders are immutable** (`chattr +i`), so nothing can write into them while the
   drive is missing. The drive's own root isn't affected. The folder underneath is only visible
   through a bind mount of `/`, which works with no downtime:

   ```bash
   mkdir -p /run/rootview && mount --bind / /run/rootview
   ls -A /run/rootview/mnt/media                # must be empty before chattr; move anything found
   chattr +i /run/rootview/mnt/media
   lsattr -d /run/rootview/mnt/*                # ----i--- on each data folder
   umount /run/rootview
   ```

   Doing this found real leftovers on both hosts: 731 old *arr config files (Aug–Sep 2026) hidden
   under skynet's `/mnt/media`, and a stray Audiobookshelf folder under little-skynet's temp-mnt.
   (The skynet files were archived to `/root/hidden-under-media-2026-09.tgz` before deleting.)
3. **Proxmox storage on a data drive** has `is_mountpoint yes` (`pvesm set nvme3 --is_mountpoint yes`),
   so Proxmox refuses to use it when the drive isn't mounted, instead of creating guest disks on the
   boot disk.
4. **host-backup checks every folder is a mounted drive** before backing it up. An empty folder
   would otherwise "succeed" and replace good backups.

Tested with a real reboot of both hosts after patching (November 2026): every drive mounted, the
immutable bits survived, no failed units.

The NVMe device numbers on skynet changed between two boots, which is why fstab and the docs use
UUIDs and serials, never `/dev/nvmeXn1`.

## Smaller changes

- **Tailscale removed from both hosts** (package, repo, its DNS settings). DNS is Pi-hole, set
  through Proxmox: `pvesh set /nodes/$(hostname)/dns --search home --dns1 192.168.50.2`.
- **Unused mounts removed:** skynet's `/mnt/remote-share` (an SMB mount with `file_mode=0777`) and
  stray folders (`/mnt/media-storage` on the host).
- **The CI runner's job images are pruned daily** (`runner-prune`), so CT 109 doesn't fill up.
- **Plex's GPU libraries are held at the host driver's version**, after an upgrade got them out of
  sync and Plex silently fell back to the CPU. **little-skynet's unused NVIDIA driver is fully
  removed.** Details, checks and the upgrade procedure: [gpu.md](gpu.md).

## Still open

- **Privileged containers with full device access** (`lxc.cgroup2.devices.allow: a`):
  little-skynet CT 100 and 101, skynet CT 100 and 102. Root in those containers is close to root on
  the host. Converting them to unprivileged (with ID-mapped bind mounts) is planned.
- **Which containers mount `/mnt/media`:** it should be only CT 100 (writers) and CT 103 (Plex,
  read-only). Check with `grep -H /mnt/media /etc/pve/lxc/*.conf`.
- **Guest Notes fields hold no secrets.** Proxmox's Notes are plain text in `/etc/pve`, which is in
  every backup. Passwords belong in Vaultwarden.
- **Host config into Ansible** (Samba, fstab options, the rsync script), so this page becomes code.
- **Monitoring:** a missing drive or a failed backup now alerts the phone ([monitoring.md](monitoring.md)).
  Disk health (SMART) and disk space aren't watched yet.
