#!/usr/bin/env bash
# Runs one playbook for the Gitea workflows, with a plain-English header before and a summary after.
#
#   run-playbook.sh <playbook> <why>
#
# Settings come from the environment (all optional):
#   CHECK_MODE=true     dry run: show what would change, change nothing
#   LIMIT=host,group    only these hosts
#   ALLOW_REBOOT=true   let patch-guests reboot guests that need it
#   EXTRA_VARS='k=v'    extra variables, passed as one argument (can only ever set variables)
#
# Run from the ansible/ folder. Secrets come from /ansible_config/secrets.yml on the Ansible LXC.
set -euo pipefail

PLAYBOOK="${1:?usage: run-playbook.sh <playbook> <why>}"
WHY="${2:-by hand}"

# One line per playbook: what it does. Also the list of playbooks this script will run.
case "$PLAYBOOK" in
  ping)               WHAT="Safe test. Logs in to every host and checks sudo. Changes nothing." ;;
  patch-guests)       WHAT="OS updates on every LXC, VM and Pi, one host at a time. Runs every Sunday by itself." ;;
  patch-hosts)        WHAT="Proxmox VE + Proxmox Backup Server updates. Never reboots." ;;
  users)              WHAT="Admin (alex) and break-glass accounts. Only needed for a new machine or a password change." ;;
  harden-ssh)         WHAT="Keys-only SSH, no root login. Only needed for a new machine." ;;
  immich)             WHAT="Deploys Immich at the version in host_vars/immich.yml (DB dump first). Runs by itself when an Immich update is merged." ;;
  portainer)          WHAT="Portainer server + agents at the version in group_vars/portainer_hosts.yml (data backup first). Runs by itself when a Portainer update is merged." ;;
  docker-cleanup)     WHAT="Removes unused Docker images and orphaned Portainer stack records." ;;
  runner-prune)       WHAT="Installs/updates the daily cleanup of the CI runner's inner Docker images (Renovate leaves ~1 GB per version)." ;;
  docker)             WHAT="Installs Docker CE from Docker's own repository on the docker_hosts group. Safe to run again." ;;
  kiwix-update)       WHAT="Installs/updates the monthly Kiwix ZIM update on survival. extra_vars kiwix_update_run_now=true also starts one now (in the background)." ;;
  host-backup)        WHAT="Installs/updates the nightly backup of host folders (e.g. /mnt/nvme1) to PBS. extra_vars host_backup_run_now=true also runs one now." ;;
  rsync-data)         WHAT="Installs/updates the nightly copies of critical data (Vaultwarden, documents, photos) to the USB disk and the Pi. extra_vars rsync_data_run_now=dry (or true) also runs one now." ;;
  health-check)       WHAT="Installs/updates the 5-minute health checks (e.g. Plex GPU) that report to Uptime Kuma. extra_vars health_check_run_now=true also runs them once." ;;
  timezone)           WHAT="Sets every machine to the timezone in group_vars/all.yml. Only needed for a new machine or a timezone change." ;;
  portainer-discover) WHAT="Report only. Shows Docker + Portainer on every host. Changes nothing." ;;
  *) echo "Unknown playbook '$PLAYBOOK'."; exit 1 ;;
esac

args=(-e "allow_reboot=${ALLOW_REBOOT:-false}")
[ -f /ansible_config/secrets.yml ] && args+=(-e @/ansible_config/secrets.yml)
[ -n "${EXTRA_VARS:-}" ] && args+=(-e "$EXTRA_VARS")
[ -n "${LIMIT:-}" ] && args+=(--limit "$LIMIT")
if [ "${CHECK_MODE:-false}" = "true" ]; then
  args+=(--check --diff)
  MODE="DRY RUN - shows what would change, changes nothing"
else
  MODE="REAL RUN - changes will be made"
fi

line="======================================================================================"
echo "$line"
echo " Playbook : $PLAYBOOK"
echo " What     : $WHAT"
echo " Why now  : $WHY"
echo " Mode     : $MODE"
echo " Limit    : ${LIMIT:-none (every host the playbook targets)}"
[ -n "${EXTRA_VARS:-}" ] && echo " Extra    : $EXTRA_VARS"
echo " Hosts it will touch:"
ANSIBLE_FORCE_COLOR=0 ansible-playbook "playbooks/$PLAYBOOK.yml" "${args[@]}" --list-hosts \
  | sed -n 's/^ *\(play #[0-9]*\) ([^)]*): \(.*[^[:space:]]\)[[:space:]]*TAGS.*/   \1: \2/p; s/^      \([^ ].*\)$/       \1/p'
echo "$line"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
rc=0
ansible-playbook "playbooks/$PLAYBOOK.yml" "${args[@]}" | tee "$log" || rc=$?

# Summary from the PLAY RECAP: which hosts had changes. Colour codes are stripped first.
changed="$(sed 's/\x1b\[[0-9;]*m//g' "$log" | awk '
  /^PLAY RECAP/ { recap = 1; next }
  recap && /changed=/ {
    n = $0; sub(/.*changed=/, "", n); sub(/ .*/, "", n)
    if (n + 0 > 0) printf "%s%s (%s)", (out ? ", " : ""), $1, n
    out = out || (n + 0 > 0)
  }')"

echo "$line"
if [ "$rc" -ne 0 ]; then
  echo " RESULT: FAILED (exit code $rc). Read the first [ERROR] above; it says what was and wasn't changed."
  if [ "${CHECK_MODE:-false}" = "true" ]; then
    [ -n "$changed" ] && echo " (Dry run: nothing was changed. Hosts that would have had changes: $changed)"
  else
    [ -n "$changed" ] && echo " Hosts that had changes before it stopped: $changed"
  fi
elif [ "${CHECK_MODE:-false}" = "true" ]; then
  if [ -n "$changed" ]; then
    echo " RESULT: dry run OK. A real run would change: $changed"
    echo " Read each host's plan above, then run again with check_mode unticked."
  else
    echo " RESULT: dry run OK. Nothing would change: there's no need to run this for real."
  fi
else
  if [ -n "$changed" ]; then
    echo " RESULT: OK. Changed: $changed"
  else
    echo " RESULT: OK. Nothing needed changing: everything was already up to date."
  fi
fi
echo "$line"
exit "$rc"
