# Monitoring and alerts

Every alert ends up as a push notification on the phone, through **ntfy**. Two things feed it:
**Uptime Kuma** (for the lab's own scripts and for uptime checks) and the **built-in notification
system of Proxmox VE and PBS** (for their backup, verify and prune jobs).

```
rsync-data, host-backup ──(each run: up / down)──► Uptime Kuma push monitors ─┐
HTTP / ping checks of the apps and hosts ────────► Uptime Kuma monitors ──────┤
PVE backup jobs (both hosts) ──(severity error)──► PVE webhook ───────────────┼──► ntfy.sh ──► phone
PBS verify / prune / GC ───────(severity error)──► PBS webhook ───────────────┘
```

## What alerts, and when

| What | Source | Alerts when |
|---|---|---|
| `rsync-data` (little-skynet, 01:00) | Kuma push monitor, heartbeat 25 h | A run fails (at once), or no run for 25 h |
| `host-backup` (skynet 02:30, little-skynet 02:45) | One Kuma push monitor per host, heartbeat 25 h | A run fails, a drive isn't mounted (at once), or no run for 25 h |
| Guest backups (little-skynet 03:00, skynet 03:30) | PVE notifications on each host | A job ends with an error |
| PBS verify, prune, garbage collection | PBS notifications | A job ends with an error |
| Apps and hosts up | Kuma HTTP/ping monitors, 2 retries | Three failed checks in a row |

## How the push monitors work (a dead man's switch)

A **push monitor** waits for the job to report in, instead of Kuma checking the job. Each run ends by
calling its monitor's URL:

- `?status=up&msg=OK` when the run ended with `RESULT: OK`,
- `?status=down&msg=...` when it failed, which alerts at once.

If **nothing** calls the URL for 25 hours, Kuma alerts too. That covers what an "on failure" hook
can't: a timer that stopped, a host that was off, a script that was removed. This pattern is called a
**dead man's switch**.

The scripts never let the report change the job's result: `curl -fsS -m 10 --retry 3`, and if Kuma
can't be reached they log a warning and carry on. Dry runs (`DRY=1`) report nothing, so a dry run
can't hide a night without a backup.

- `rsync-data` reports at its end. `host-backup` reports from an `EXIT` trap, so the early exit
  for a missing drive is reported too.
- Code: [rsync-data.sh.j2](../ansible/templates/rsync-data/rsync-data.sh.j2),
  [host-backup.sh.j2](../ansible/templates/host-backup/host-backup.sh.j2).

## Proxmox VE and PBS notifications

Set up by hand in each machine's UI (skynet, little-skynet: Datacenter → Notifications; PBS:
Configuration → Notifications):

- **Target** `ntfy`: a webhook, `POST https://ntfy.sh/{{ secrets.topic }}`. The topic is a
  **webhook secret**: it isn't shown in the UI, and it's stored in the root-only private file
  (PVE: `/etc/pve/priv/notifications.cfg`, PBS: `notifications-priv.cfg`) instead of the readable
  `notifications.cfg`. The private file is still in host-backup's `pve` archive, which is one more
  reason those archives must be encrypted before any off-site copy. Headers: `Title: {{ title }}`,
  `Priority: 4`, `Tags: warning`.
- **The body is a fixed sentence, not the job log.** A failed job's message holds guest names,
  storage names and error details, and ntfy.sh is a public server. The title says what failed and
  where; the details are in the UI.
- **Matcher** `failures-to-phone`: severity `error` → `ntfy`. Warnings and info (e.g. available
  updates) aren't sent, so the phone only buzzes for something to fix.
- The backup jobs use "global notification settings", and the PBS datastore's notification mode is
  "Notification system". In the legacy email mode, jobs never reach the matcher.
- The default matcher (`mail-to-root`) is left in place. There's no mail relay, so that mail stays
  on the host.

## ntfy

[ntfy](https://ntfy.sh) is an open-source push service with a phone app. The lab uses the public
server with one topic for everything.

- **The topic name is the password.** Anyone who knows it can read the alerts or send fake ones.
  It's a long random name, kept in Vaultwarden, the Kuma notification and the PVE/PBS webhook
  secrets, never in this repo. If it leaks: make a new topic, update those three places,
  resubscribe the phone.
- **Messages say what failed and where, nothing more:** no paths, IPs or secrets. ntfy.sh keeps
  messages for a few hours.
- Kuma's ntfy notification uses priority 4 (high), so a down alert breaks through.

## Where the secrets live

| Secret | Lives in | Used by |
|---|---|---|
| ntfy topic | Vaultwarden; Kuma's notification; the `topic` secret of each PVE/PBS webhook | Everything that alerts |
| `rsync_data_push_url` | `/ansible_config/secrets.yml` → `/etc/rsync-data.env` (0600) on little-skynet | `rsync-data` |
| `host_backup_push_urls` (one per host) | `/ansible_config/secrets.yml` → `/etc/host-backup.env` (0600) on each host | `host-backup` |

A push URL is the URL **without** Kuma's example query: it ends in `/api/push/<token>`. The
scripts add their own `?status=...`. Anyone with a push URL can mark that job healthy, so each one
is treated as a secret.

## Adding a push monitor for a new job

1. Kuma → Add New Monitor → **Push**. Heartbeat: the job's interval plus slack (daily: `90000` s),
   retries `0`, notification `ntfy phone`. Copy the push URL up to the token.
2. Put the URL in `/ansible_config/secrets.yml` and have the playbook install it in a root-only
   (`0600`, `no_log`) env file on the host.
3. In the job's script: a `push()` like the ones above, called with `up` or `down` on every way
   out (an `EXIT` trap is the safest).
4. Test both directions by hand:
   `curl -fsS "$PUSH_URL?status=down&msg=test"`, then `status=up`.

## Gaps

- **Kuma runs on little-skynet** (CT 101). If little-skynet is down, nothing alerts about anything,
  including about little-skynet. Accepted for now; the fix is a separate monitoring device (see the
  roadmap).
- **A disabled or deleted PVE/PBS job stays silent.** Their notifications only fire when a job runs
  and fails.
- **Not watched yet:** Plex's GPU (see [gpu.md](gpu.md)), disk health (SMART), disks filling up,
  failed `patch-guests` runs, the PBS datastore's free space.
