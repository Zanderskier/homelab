# Ansible

Ansible keeps the operating system of every machine up to date. It runs on its own **Ansible LXC**
on skynet (the "control node"), which has a Gitea runner registered with the label `ansible`. The
Ansible workflows send their jobs there, and Ansible connects to each machine over SSH as a dedicated
`ansible` user.

```
Gitea (schedule / merge / Run workflow) ──► Ansible LXC on skynet ──SSH──► every LXC, VM, Pi, Proxmox host
                                    (runner "ansible", key lives here)
```

Because Ansible no longer runs on the Docker runner (`gitea-runner`, lint + Renovate), that
runner can be patched like any other LXC.

```
ansible/
  ansible.cfg              settings: which inventory, which user, strict host-key checking
  inventory/hosts.yml      every machine, sorted into groups (proxmox, pbs, guests, pis)
  inventory/group_vars/    variables per group (all.yml applies to every host)
  playbooks/
    ping.yml               safe test: log in, show OS, check sudo. Changes nothing
    patch-guests.yml       apt full-upgrade on LXCs, VMs, Pis + `pihole -up`. Weekly schedule
    patch-hosts.yml        apt full-upgrade on Proxmox VE + PBS. Manual only, never reboots
    users.yml              admin + break-glass accounts on every machine
    harden-ssh.yml         no root or password SSH logins (break-glass excepted, LAN/VPN only)
    immich.yml             deploys Immich at the version in host_vars/immich.yml
    portainer-discover.yml read-only report: Docker + Portainer on every host, environments, stacks
    portainer.yml          Portainer server + standard agents, one pinned version, environments via API
    host-backup.yml        nightly PBS backup of host folders that Proxmox backups skip (bind mounts)
    docker-cleanup.yml     unused images, orphaned Portainer stack records. Safe any time
    runner-prune.yml       daily timer that prunes the CI runner's inner Docker (job images)
    docker.yml             Docker CE from Docker's own repository on the docker_hosts group
    timezone.yml           same timezone (group_vars/all.yml) on every machine
    kiwix-update.yml       monthly update of the offline Wikipedia/ZIM files on survival (never deletes)
  templates/               compose files the playbooks render onto hosts
  files/                   scripts and keys the playbooks copy to hosts
  run-playbook.sh          what every workflow calls: prints what, why, mode and hosts first,
                           and a one-line RESULT at the end (what changed, or "nothing needed")
  bootstrap/
    setup-control-node.sh  one-time: turns a fresh LXC into the Ansible LXC
    bootstrap-ssh.sh       one-time per machine: creates the ansible user + authorizes the key
  known_hosts              host public keys, so Ansible can verify it's talking to the real machine
  requirements.txt / .yml  pinned Ansible + collection versions (Renovate keeps them current)
```

## When it runs

| Trigger | Workflow | Playbook | Reboots? |
|---|---|---|---|
| Every Sunday 04:30 Pacific (05:30 in summer), after the PBS backups | `ansible` | `patch-guests` | No. The summary says `REBOOT NEEDED` where one is due |
| An Immich change is merged to main | `deploy-immich` | `immich` | No |
| `portainer_version` changes on main (a merged Renovate PR) | `deploy-portainer` | `portainer` | No |
| Actions → ansible → **Run workflow** | `ansible` | your choice | Only if you tick *allow_reboot* (guests only) |

Each run's name in the Actions list says what it was, e.g. `portainer - ...  [DRY RUN]` or
`portainer deploy: Update portainer/portainer-ce to v2.45.4`.

### Which playbook do I run?

Usually none: the schedule and the two deploy workflows cover normal operation.

| Playbook | Run it when | Changes things? |
|---|---|---|
| `ping` | testing that Ansible can reach everything | No |
| `portainer-discover` | you want a report of Docker + Portainer on every host | No |
| `patch-guests` | you want updates before Sunday | Yes |
| `patch-hosts` | Proxmox or PBS updates are waiting (by hand only) | Yes, never reboots |
| `docker-cleanup` | disks are filling up, or Portainer shows stacks for hosts that are gone | Yes, removes only unused things |
| `immich`, `portainer` | a deploy failed and you've fixed the cause, or you edited a template | Yes |
| `host-backup` | you changed what's backed up, or the PBS token | Yes (files + timer only) |
| `runner-prune` | a new runner, or you changed `runner_prune_time` | Yes (timer only) |
| `users`, `harden-ssh` | a new machine, or a password change | Yes |
| `timezone` | a new machine, or a schedule runs at the wrong hour | Yes (timezone only) |
| `kiwix-update` | you changed the ZIM list in `host_vars/survival.yml`, or want an update now (`kiwix_update_run_now=true`) | Yes (script + timer; the download runs on survival) |
| `docker` | a new Docker machine (add it to `docker_hosts` in the inventory first) | Yes (installs Docker only) |

Safety on the Run workflow form:
- **Dry run is ticked by default.** Untick it only after reading the dry run's plan.
- The first lines of every run say what the playbook does, why it ran, the mode and every host it
  will touch. The last lines give a `RESULT`: which hosts changed (or would change), or
  `Nothing needed changing`. A dry run that says *nothing would change* means there's no need to
  run it for real.
- Skipped tasks aren't printed (`display_skipped_hosts = False` in `ansible.cfg`), so what's left is
  what was checked or changed.

## One-time setup

### 1. Create the Ansible LXC (skynet)

CT 110 on skynet: unprivileged **Debian 13**, hostname `Ansible`, 2 cores, 2 GB RAM, 8 GB root
disk, DHCP reservation **192.168.50.129**. No Docker needed.

Everything the runner keeps is in **`/ansible_config`** on the LXC's root disk: its Gitea
registration (`.runner`), the SSH key (`.ssh/`), the Ansible venv (`.venvs/`), and job workspaces.
Because it's on the root disk, **PBS backs it up with the LXC**. Restoring CT 110 brings back a
working control node with the same key, so no bootstrap needs re-running.

Expect it to use about 1–2 GB, mostly Python and the Ansible collections. 8 GB is enough.

### 2. Turn it into the control node

1. `alex/homelab` → Settings → Actions → **Runners → Create new runner** → copy the token.
   (Create it at the **repo** level, so this runner only takes jobs from the homelab repo.)
2. In the LXC console as root, paste in `bootstrap/setup-control-node.sh` (`nano setup.sh`), then:
   ```bash
   bash setup.sh http://192.168.50.124:3000 <token>
   ```
3. It ends by printing the **public key**:
   - Put it in `PUBKEY=` at the top of `bootstrap/bootstrap-ssh.sh` (`ALLOW_FROM` is already
     `192.168.50.129`).
   - Save it as `ansible/files/ansible_ed25519.pub`.
4. The runner `ansible-lxc` should show as **Idle** under the repo's Settings → Actions → Runners.

The private key stays in `/ansible_config/.ssh/` and nowhere else.

### 3. Authorize the key on every machine (as root)

Copy `bootstrap/bootstrap-ssh.sh` over (with `PUBKEY` filled in), then:

| Machine | Command |
|---|---|
| skynet (Proxmox shell) | `bash bootstrap-ssh.sh lxcs` then `bash bootstrap-ssh.sh self` |
| little-skynet (Proxmox shell) | `bash bootstrap-ssh.sh lxcs` then `bash bootstrap-ssh.sh self` |
| Immich VM, PBS, Pi 2, Pi 4 | `sudo bash bootstrap-ssh.sh self` |

`lxcs` sets up every **running** LXC on that host, including the Ansible LXC itself (harmless).
Each machine prints `ok: <hostname> <ip>`.

**New machines after SSH hardening.** Root SSH is off everywhere, so copy the script to the new
machine's Proxmox host as **alex** (`scp bootstrap-ssh.sh alex@192.168.50.8:~/`), then run it
there with `sudo`:

- **New LXC:** on its Proxmox host, `sudo bash ~/bootstrap-ssh.sh lxcs` (or run it from the
  Proxmox web UI → node → **Shell**, which is root).
- **New VM or Pi:** copy it to the machine as its first user, then `sudo bash bootstrap-ssh.sh self`.

Then add it to `inventory/hosts.yml` and `known_hosts`, and run `users` + `harden-ssh` with
`limit` set to the new host.

### 4. Record each host's identity (known_hosts)

On the Ansible LXC:

```bash
# every ansible_host in the inventory
grep -oE 'ansible_host: [0-9.]+' inventory/hosts.yml | cut -d' ' -f2 | xargs ssh-keyscan -t ed25519
```

Paste the output into `ansible/known_hosts` and commit it. Re-scan a host if you rebuild it.

### 5. Test

1. Actions → **ansible** → Run workflow → playbook **ping**. Every host should be green.
2. **patch-guests**, dry run (the default): a preview of the updates, nothing applied.
3. **patch-guests** with dry run unticked and **limit** `pis`.

### Running by hand (learning / debugging)

On the Ansible LXC:

```bash
sudo -iu runner
git clone http://192.168.50.124:3000/alex/homelab.git && cd homelab/ansible   # first time only
~/.venvs/ansible/bin/ansible-playbook playbooks/ping.yml
~/.venvs/ansible/bin/ansible pis -m ansible.builtin.command -a "uptime"     # one-off command
```

The venv exists after the first workflow run.

## Admin user and SSH hardening

Two playbooks replace "log in as root everywhere":

| Playbook | What it does |
|---|---|
| `users` | Creates **`alex`** (SSH key login from `files/alex.pub`) and a **break-glass** account (password only) on every machine. Both get full root rights through `sudo`, which asks for their password |
| `harden-ssh` | Turns off SSH logins **as root** and **with passwords**, except for the break-glass account from the LAN/VPN. Refuses to run on a host where alex has no key |

Accounts after this:

| Account | Logs in with | From | Can do |
|---|---|---|---|
| `alex` (me, daily) | my SSH key | anywhere SSH is reachable | anything, via `sudo` + password |
| break-glass (name in Vaultwarden) | **password** (Vaultwarden) | **LAN `192.168.50.0/24` and VPN `10.8.0.0/24` only** | anything, via `sudo` + password |
| `ansible` (automation) | the control node's key | 192.168.50.129 only | anything, via `sudo` without a password |
| `root` | console only (Proxmox shell, `pct enter`, VM console, JetKVM) | — | last resort |

The break-glass account is for logging in from a machine that doesn't have my key: a new laptop,
a friend's PC over the VPN. Its **name is not in this repo** either, so the public repo doesn't say
which account accepts passwords. The VPN subnet is in `inventory/group_vars/all.yml`. Check it
matches the router (VPN → OpenVPN).

### Secrets (Ansible LXC only, never in Git)

```bash
# On the Ansible LXC
sudo -iu runner
openssl passwd -6       # run twice: once for alex's sudo password, once for break-glass
nano /ansible_config/secrets.yml
chmod 600 /ansible_config/secrets.yml
```

`/ansible_config/secrets.yml`:

```yaml
alex_password_hash: '$6$...'          # alex's sudo password
breakglass_user: 'pick-a-name'        # not "admin"/"breakglass": something not guessable
breakglass_password_hash: '$6$...'    # a different, long password (generate it in Vaultwarden)
portainer_api_token: 'ptr_...'        # optional: lets portainer-discover list environments and stacks
pbs_host_backup_secret: '...'        # host-backup: the PBS API token's secret (host-backup@pbs!skynet)
```

Keep the single quotes: the hashes contain `$`. Store both passwords and the break-glass name in
Vaultwarden. The workflow loads this file automatically, and `users` refuses to run if anything is
missing or both passwords are the same.

**`portainer_api_token`:** create it in Portainer (your user name, top right → **My account →
Access tokens**). Portainer CE tokens can't be limited: one has the full rights of the user that
made it, which for an admin means control of Docker on every host. That's why it lives only in this
file. The `portainer-discover` playbook is read-only and prints stack variable **names**, never
values.

### Order (don't skip the testing)

1. Run `users` with **check_mode**, then for real.
2. From the PC, on a few hosts: `ssh alex@192.168.50.81`, then `sudo -v`. Both must work.
3. Run `harden-ssh` with **limit** set to one host, then test `ssh alex@` and confirm `ssh root@` is
   refused.
4. Run `harden-ssh` on everything, with the Pis last (`limit: pis`). They have no web console, so
   a mistake there means plugging in a keyboard and monitor.

## Immich

Immich runs with docker compose on the Immich VM (`/mnt/immich/immich`, a virtiofs share from
little-skynet). Ansible deploys it, not Portainer.

```
Renovate PR: immich_version v3.3.5 -> v3.4.0   (host_vars/immich.yml, never auto-merged)
   │  read the release notes, merge
   ▼
deploy-immich workflow (triggered by the merge to main)
   1. pg_dumpall -> /mnt/immich/immich/pre-update-dumps/immich-<old version>-<date>.sql.gz (keeps 5)
   2. docker-compose.yml from the repo (old one kept as docker-compose.yml.<date>~)
   3. IMMICH_VERSION="v3.4.0" in .env (the only line Ansible changes; password and paths untouched)
   4. docker compose pull && up -d --wait
   5. /api/server/ping must answer "pong", and /api/server/version must report v3.4.0
```

- **Changing the version by hand:** edit `immich_version` in `inventory/host_vars/immich.yml` and
  push (that deploys it), or run the `immich` playbook from the Actions tab.
- **Release notes say "update docker-compose.yml":** paste the new upstream file into
  `stacks/little-skynet/immich/compose.yaml`, below the homelab notes, in the same PR as the version
  bump.
- **Backups:** the VM's own disk is in PBS, but `/mnt/immich` (photos + database) is **not**. PBS
  doesn't back up virtiofs. It's covered by the critical-data backup and Immich's built-in database
  backups (Administration → Settings → Backup), plus the pre-update dumps above.

### Rolling back a bad upgrade

Upgrades usually migrate the database, so an older Immich can't simply start on a newer database.
Roll back by restoring the dump taken just before the upgrade, using **the version in the dump's
file name**:

```bash
ssh 192.168.50.106           # as alex
cd /mnt/immich/immich
sudo sed -i 's/^IMMICH_VERSION=.*/IMMICH_VERSION="v3.3.5"/' .env     # the version in the dump name
sudo docker compose down
sudo mv postgres postgres.broken-$(date +%F)                         # keep it until the restore works
sudo docker compose pull && sudo docker compose create
sudo docker start immich_postgres && sleep 15
gunzip --stdout pre-update-dumps/immich-v3.3.5-<date>.sql.gz \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | sudo docker exec -i immich_postgres psql --dbname=postgres --username=postgres
sudo docker compose up -d
```

That restore follows Immich's backup-and-restore guide. Then set `immich_version` back in the repo
too, so the next run doesn't upgrade again, and close or ignore Renovate's PR until the problem is
fixed upstream.

## Portainer

One Portainer server (192.168.50.81) is the single pane of glass. Every other host that should
appear in it runs a **standard agent**, which the server connects to on port 9001. Ansible manages
all of them from one version, so they can't drift apart.

| | Server (`portainer`) | Agents (`gitea-runner`, `cloudflared`, `arr-stack`, `authentik`, `gitea`) |
|---|---|---|
| Config folder | `/opt/portainer` | `/opt/portainer-agent` |
| Shortcut | `/root/portainer` → config folder | `/root/portainer` → config folder |
| What runs | `compose.yaml` there (project `portainer`) | `compose.yaml` there (project `portainer-agent`) |
| Data | existing volume `root_portainer_data`, also linked as `/opt/portainer/data` | none (agents are stateless) |
| Backups | `/opt/portainer/backups/`, taken before every redeploy, newest 5 kept | — |

The compose files are rendered from `ansible/templates/`. Edit those, or the variables in
`inventory/group_vars/portainer_hosts.yml`, never the files on the hosts.

**Stacks are not managed here.** They live in the server's data volume, deploy from this repo by
Git polling, and are untouched by this playbook. The volume is declared `external`, so the playbook
can never start an empty Portainer: if the volume is missing, it stops.

### What a run does

```
server:  pull image -> stop -> tar the data volume -> remove old container -> compose up
         -> wait until its API reports the pinned version
agents:  one host at a time: pull -> remove the old agent container (docker run, another compose
         file, or an Edge agent) -> compose up -> wait until /ping reports the pinned version
API:     add an environment for any agent host that has none (add only) -> ask Portainer to
         re-check each agent -> fail unless every agent rolled out in this run is up and current
```

- A host that's already managed and on the right version reports **"Nothing to do"**.
- **Check mode** shows the plan for every host and the compose file diffs, and touches no container.
- **limit** works per host. The environment step only runs when `portainer` is in the run.
- Old config files are renamed to `<name>.retired`, never deleted.
- The playbook **never edits or deletes an environment**. When a host changes agent type (Edge to
  standard), it adds the new environment; delete the old one in Portainer once you've checked it.
- It needs `portainer_api_token` in `/ansible_config/secrets.yml` for the API step. Without it,
  the containers are still deployed, and it tells you which environments to add by hand.

### Updating Portainer

Renovate opens a PR that changes `portainer_version` (2.45.x patches only; never auto-merged).
**Merging it deploys it:** the `deploy-portainer` workflow runs the playbook, which upgrades the
server first, then the agents, as Portainer's upgrade guide says. Watch it in the Actions tab.

Only the version file triggers a deploy. After changing `portainer.yml` or the templates, run the
**portainer** playbook by hand: dry run first, then for real.

To move to a newer LTS line, change `allowedVersions` for Portainer in `renovate.json` and
`portainer_version` together, after reading the release notes.

### Rolling back the server

A failed run tries to start the existing container again and tells you where the backup is. To go
back to the data and version from before a run, on 192.168.50.81 as root:

```bash
cd /opt/portainer
docker compose down                     # removes the container only; the data volume is external
ls -lh backups/                         # the file name holds the version and time it was taken
find data/ -mindepth 1 -delete          # empty the volume (data/ is a link to it)
tar -xzf backups/portainer-data-<version>-<time>.tar.gz -C data/
sed -i 's|portainer-ce:.*|portainer-ce:<version>|' compose.yaml
docker compose up -d
```

Then set `portainer_version` back to that version in the repo, so the next run doesn't upgrade
again. If the host itself is broken, restore the LXC from PBS instead.

### Shared agent secret

The server and every agent share one `AGENT_SECRET`, from `portainer_agent_secret` in
`/ansible_config/secrets.yml`, so an agent only obeys a server that knows it. Without it, an agent
obeys the first Portainer server that connects after each restart, and since agents mount `/` and
the Docker socket, that would be root on the host for anything on the LAN or VPN.

To rotate it: generate a new value (`openssl rand -base64 32`), replace it in `secrets.yml` and
Vaultwarden, then run the **portainer** playbook (dry run first). The compose files that hold it are
mode 600 and never shown in a diff, so the secret stays out of the Actions log.

## Housekeeping (`docker-cleanup`)

| Part | Hosts | What it removes |
|---|---|---|
| Unused images | every guest with Docker | images no container uses (`docker image prune -a`). Volumes and networks are never pruned |
| Portainer records | `portainer` | orphaned stack records, and stack folders with no record. Their files go to `/opt/portainer/retired-stacks` (root only) first |

Portainer deletes a stack by tearing it down on whichever environment the request names. An
orphan with the same name as a live stack (the old `arr-stack` record) would take the live one down
if deleted through its environment, **which is what the Portainer UI does**. So the playbook
deletes each orphan through the `gitea-runner` environment, after checking no container there
belongs to a compose project with that name. Remove orphans with this playbook, not in the UI.

Check mode lists what would be removed. Delete `/opt/portainer/retired-stacks` when you no longer
need the old files.

### The CI runner's job images (`runner-prune`)

The Gitea runner (CT 109) is Docker-in-Docker: job images live in a Docker daemon *inside* the
`gitea-runner-1` container (volume `runner-docker`), where a normal `docker image prune` can't see
them. Renovate's image is about 1 GB and Renovate bumps its own pin, so each new version leaves the
old one behind. In November 2026 that filled CT 109's disk to 99% (29 GB of old Renovate images).

- `runner-prune` installs a timer on every host with `docker_inner_daemon` in its host_vars. It runs
  `docker exec <container> docker image prune -a -f` daily at `runner_prune_time` (`host_vars/gitea-runner.yml`).
- `docker-cleanup` also prunes the inner daemon, for a one-off cleanup.
- Check it on CT 109: `systemctl list-timers runner-prune.timer` and `journalctl -u runner-prune.service`.
- Pruning frees space inside the container's disk, but the LVM-thin pool on skynet only gets the blocks
  back after `pct fstrim 109` on skynet.

## Host folder backups (`host-backup`)

Proxmox backs up each container's own disk, but **never its bind mounts** (`mpX: /mnt/...`). On
skynet, Gitea, Authentik and gitea-runner keep their data on `/mnt/nvme1`, and the survival LXC's
Kiwix library is on `/mnt/nvme0`. Both are bind mounts, so they were in no backup until this.
Every night at 02:30 (before the 03:30 Proxmox backups), skynet runs:

```
1. check each folder is a mounted drive   fstab has nofail: a dead drive leaves an empty folder,
                                          and backing that up would look like success
2. pg_dumpall Gitea's database            -> /mnt/nvme1/db-dumps/ (newest 3 kept), a consistent copy
3. proxmox-backup-client backup           -> PBS, namespace "hosts", backup host/skynet
                                          (nvme1.mpxar/.ppxar, nvme0.mpxar/.ppxar)
```

- **What's backed up:** `inventory/host_vars/skynet.yml`. **PBS details:** `group_vars/all.yml`.
  **Token secret:** `pbs_host_backup_secret` in `/ansible_config/secrets.yml`.
- **Least privilege:** the API token `host-backup@pbs!skynet` has `DatastoreBackup` on the `hosts`
  namespace only: it can add backups there, and can't see, change or delete the container backups.
- **Retention:** a PBS prune job on the `hosts` namespace (7 daily, 4 weekly, 6 monthly).
- **Logs:** `journalctl -u host-backup.service` on skynet. Run one now:
  `systemctl start host-backup.service`.
- **little-skynet** does the same at 02:45 for `/mnt/second-drive` (Immich's photos), as
  `host/little-skynet`. It leaves out the live database folder (`immich/postgres`). The database is
  restored from Immich's own nightly dumps in `immich/library/backups`, which are in the backup.

**Fast nightly runs, full read weekly.** Each night the client only reads files whose size, mtime,
owner or permissions differ from the last backup (`--change-detection-mode=metadata`). Unchanged
files point at data already in PBS, so a night with few changes takes minutes, not the 40 minutes a
full read of Immich takes. The one thing that can slip past this is a file whose contents changed
but whose size and mtime didn't (rare, e.g. a tool that restores the old mtime). So once a week
(`host_backup_full_read_day` in `group_vars/all.yml`, Sunday) every file is read again
(`--change-detection-mode=data`). Each run's log says which mode it used.

**Host config too.** Both hosts also send their own config, listed once in
`host_backup_config_paths` (`group_vars/all.yml`): `etc`, `pve`, `root` and `crontabs` archives
(`/etc`, `/etc/pve`, `/root`, `/var/spool/cron/crontabs`). That's fstab, Samba, the network, every
guest's config, storage and backup jobs, and hand-made scripts such as `rsync-data.sh`. `/etc/pve`
is its own archive because it's a separate filesystem (Proxmox's pmxcfs) mounted on `/etc`, and the
client never crosses into another filesystem: the `etc` archive alone would silently leave it out.
These archives hold secrets (`/etc/pve/priv`, the PBS token, SMB credentials), so an off-site copy
must be encrypted. To get one file back, e.g. a guest's config: PBS UI → `host/<host>` → a
snapshot → `pve.mpxar` → `lxc/107.conf` → Download.

These backups are stored as two archives per folder, `<name>.mpxar` (file list) and
`<name>.ppxar` (contents). Snapshots from before the change are a single `<name>.pxar`.

**Restoring.** PBS UI → Datastore → Content → namespace `hosts` → `host/skynet` → a snapshot →
`nvme1.mpxar` → browse or download single files. All of it, on skynet:

```bash
set -a; . /etc/host-backup.env; set +a
proxmox-backup-client snapshot list --ns hosts
proxmox-backup-client restore --ns hosts host/skynet/<time> nvme1.mpxar /mnt/nvme3/restore-nvme1
# (older snapshots: nvme1.pxar)
```

For Gitea, stop its containers, put the files back, then (if the database files are damaged) load
the newest dump from `db-dumps/` into a fresh `gitea-db` with `gunzip -c ... | psql -U gitea`.

## Adding a machine

1. **Before first boot:** a DHCP reservation on the router for its MAC, so it never gets another
   address (the old one would end up in leases, `known_hosts` and monitoring). For an LXC, also
   Options → Start at boot, and add it to its host's PBS backup job.
2. Run `bootstrap-ssh.sh self` on it (or `lxcs` on its Proxmox host). It prints
   `ok: <hostname> <ip>`.
3. Add it under the right group in `inventory/hosts.yml`, with a comment saying what it is
   (`# CT 111: ...`). Docker hosts also go in `docker_hosts`, and in `portainer_agents` if
   Portainer should manage them.
4. Add its key to `known_hosts` (`ssh-keyscan -t ed25519 <ip>` on the Ansible LXC). Compare it with
   the key on the machine itself (`pct exec <id> -- cat /etc/ssh/ssh_host_ed25519_key.pub`): a scan
   trusts whatever answers on that IP. Two hosts with the same key means a cloned CT; regenerate
   its host keys.
5. Run, each as a dry run first, with `limit` set to the new host: `ping`, `users`,
   `harden-ssh`, `timezone`, then `docker` (Docker hosts).
6. For a Portainer agent: run `portainer` with **no limit** (or `portainer,<host>`). A limit
   filters every play, and the plays that register the environment run on the Portainer server,
   so `limit: <host>` installs the agent but silently never adds it to Portainer.
7. If it gets Proxmox firewall rules: add the rules first, check `/etc/pve/firewall/<id>.fw`
   (no `|` in front of a rule means it's enabled), and only then set Firewall: Yes.

## Offline library (`kiwix-update`)

The survival LXC (CT 101) serves ZIM files (Wikipedia, medicine, repair, preparedness) with
kiwix-serve (`stacks/skynet/survival`). Which files, and where: `inventory/host_vars/survival.yml`
(`kiwix_zims`, each with a `folder` on download.kiwix.org). On the 1st of each month at 04:00 a
systemd timer runs `/usr/local/sbin/kiwix-update`, which for each ZIM:

```
1. find the newest file on download.kiwix.org      (name_YYYY-MM.zim)
2. already in current/?                             -> "up to date", next
3. enough free space?                               (size from the server)
4. download into incoming/ (resumes), and its .sha256
5. checksum wrong                                   -> delete the download, FAILED
6. new file under kiwix_min_size_percent (95%) of the old one -> HOLD (upstream may have
   removed content; the download stays in incoming/ for a look, current/ is untouched)
7. old version -> archive/, new one -> current/, restart Kiwix
```

**Nothing is ever deleted** from `current/` or `archive/`, so content removed upstream stays here.
Prune `archive/` by hand when the disk needs it. The log ends with `RESULT: OK` or
`RESULT: FAILED or HELD`: `journalctl -u kiwix-update`. Run one now: the playbook with
`kiwix_update_run_now=true` (it starts in the background; follow it with
`sudo journalctl -fu kiwix-update`).

The files live on skynet's `/mnt/nvme0/survival` (bind mount `/srv/survival`), so the guest
backup doesn't include them. host-backup does (`nvme0` archive).

## Maintenance

- **The Ansible LXC** installs its own security updates (unattended-upgrades). Ansible doesn't
  patch it, because that would interrupt the job doing the patching.
- **The runner binary on it** is updated by hand: change `RUNNER_VERSION` in
  `setup-control-node.sh` and re-run it (registration and key are kept).

## Security notes

- The `ansible` user has **no password**. Only the homelab key can log in, and only from the
  Ansible LXC's IP (`from=` in `authorized_keys`).
- It has passwordless sudo, so that key is effectively root on every machine. It never leaves the
  Ansible LXC, isn't stored in Gitea, and the LXC only runs this one job.
- Anyone who can push workflow changes to `alex/homelab` can run commands on the Ansible LXC. Keep
  repo write access to yourself and `renovate-bot`.
- To revoke access everywhere: delete `/home/ansible/.ssh/authorized_keys` on each machine (or
  re-run the bootstrap with a new key).
