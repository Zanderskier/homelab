#!/usr/bin/env bash
# One-time setup so Ansible can log in to a machine. Run as root.
#
#   bash bootstrap-ssh.sh self    on any machine (Pi, VM, PBS, or the Proxmox host itself)
#   bash bootstrap-ssh.sh lxcs    on a Proxmox host: sets up every RUNNING LXC on that host
#
# It creates an "ansible" user that has no password (only the homelab key can log in, and only from
# the Ansible LXC) and can use sudo without a password. Safe to run again: it rewrites the same
# settings.
set -euo pipefail

# Both values are printed at the end of setup-control-node.sh.
# Public half of the Ansible key (also in ansible/files/ansible_ed25519.pub). Safe to share.
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILbupxsngQjbM3psIPg3ztEW2W8EWvwb6RvQchwBsZ7a ansible@homelab"
# The key only works when the login comes from this address: the Ansible LXC.
ALLOW_FROM="192.168.50.129"

bootstrap() {
  local pubkey="$1" allow_from="$2" need=()
  export DEBIAN_FRONTEND=noninteractive
  [ -x /usr/sbin/sshd ] || need+=(openssh-server)
  command -v sudo >/dev/null 2>&1 || need+=(sudo)
  command -v python3 >/dev/null 2>&1 || need+=(python3)
  if [ ${#need[@]} -gt 0 ]; then
    apt-get update -qq && apt-get install -y -qq "${need[@]}" >/dev/null
  fi

  id ansible >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --comment "Ansible automation" ansible
  usermod -p '*' ansible   # no password exists, so password login is impossible

  install -d -m 700 -o ansible -g ansible /home/ansible/.ssh
  printf 'from="%s",no-agent-forwarding,no-X11-forwarding,no-port-forwarding %s\n' \
    "$allow_from" "$pubkey" > /home/ansible/.ssh/authorized_keys
  chown ansible:ansible /home/ansible/.ssh/authorized_keys
  chmod 600 /home/ansible/.ssh/authorized_keys

  echo 'ansible ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ansible
  chmod 440 /etc/sudoers.d/ansible
  visudo -cf /etc/sudoers.d/ansible >/dev/null

  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  echo "ok: $(hostname) $(hostname -I | awk '{print $1}')"
}

if [ "$PUBKEY" = "PASTE_PUBLIC_KEY_HERE" ]; then
  echo "Edit this script first: put the Ansible public key in PUBKEY at the top." >&2
  exit 1
fi

case "${1:-}" in
  self)
    bootstrap "$PUBKEY" "$ALLOW_FROM"
    ;;
  lxcs)
    command -v pct >/dev/null || { echo "'lxcs' only works on a Proxmox host." >&2; exit 1; }
    for id in $(pct list | awk 'NR>1 && $2=="running" {print $1}'); do
      echo "== CT $id ($(pct config "$id" | awk '/^hostname:/ {print $2}'))"
      pct exec "$id" -- bash -c "$(declare -f bootstrap); bootstrap '$PUBKEY' '$ALLOW_FROM'" \
        || echo "!! CT $id failed, continuing with the rest"
    done
    ;;
  *)
    echo "usage: $0 self|lxcs" >&2
    exit 1
    ;;
esac
