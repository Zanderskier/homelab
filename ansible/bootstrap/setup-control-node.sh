#!/usr/bin/env bash
# One-time setup for the Ansible LXC on skynet (the "control node"). Run as root:
#
#   bash setup-control-node.sh <gitea-url> <runner-registration-token>
#   e.g. bash setup-control-node.sh http://192.168.50.124:3000 AbC123...
#
# Get the token from alex/homelab > Settings > Actions > Runners > Create new runner.
# A repo-level runner only ever receives jobs from the homelab repo.
#
# What it does:
#   - installs git, node (for actions/checkout), ssh and automatic security updates for this LXC
#   - installs the Gitea runner as a service that runs jobs labelled "ansible" directly on this LXC
#   - creates the Ansible SSH key, which never leaves this machine
# Safe to run again: existing key and registration are kept.
set -euo pipefail

RUNNER_VERSION="6.0.0"
GITEA_URL="${1:?usage: $0 <gitea-url> <runner-registration-token>}"
TOKEN="${2:?usage: $0 <gitea-url> <runner-registration-token>}"
# Everything the runner keeps (registration, SSH key, Ansible venv, job workspaces) lives in one
# easy-to-find folder on the LXC's own root disk, so PBS backs it up with the LXC.
RUNNER_HOME="${RUNNER_HOME:-/ansible_config}"
mkdir -p "$RUNNER_HOME"

echo "== Packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git curl ca-certificates nodejs openssh-client unattended-upgrades >/dev/null

# Ansible doesn't patch the machine it runs on, so this LXC updates itself.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "== Runner user and binary"
id runner >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$RUNNER_HOME" --shell /bin/bash runner
chown runner:runner "$RUNNER_HOME"
chmod 750 "$RUNNER_HOME"
curl -fsSL -o /usr/local/bin/gitea-runner \
  "https://gitea.com/gitea/runner/releases/download/v${RUNNER_VERSION}/gitea-runner-${RUNNER_VERSION}-linux-amd64"
chmod 755 /usr/local/bin/gitea-runner

echo "== Ansible SSH key"
sudo -u runner bash -c '
  install -d -m 700 ~/.ssh
  [ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "ansible@homelab" -f ~/.ssh/id_ed25519
'

echo "== Register with Gitea"
if [ ! -f "$RUNNER_HOME/.runner" ]; then
  sudo -u runner bash -c "cd '$RUNNER_HOME' && gitea-runner register --no-interactive \
    --instance '$GITEA_URL' --token '$TOKEN' --name ansible-lxc --labels ansible:host"
else
  echo "already registered (delete $RUNNER_HOME/.runner to register again)"
fi

echo "== Service"
cat > /etc/systemd/system/gitea-runner.service <<EOF
[Unit]
Description=Gitea runner for Ansible jobs
After=network-online.target
Wants=network-online.target

[Service]
User=runner
WorkingDirectory=$RUNNER_HOME
ExecStart=/usr/local/bin/gitea-runner daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now gitea-runner
systemctl --no-pager --lines=3 status gitea-runner || true

echo
echo "== Done. Ansible public key (put this in bootstrap-ssh.sh and ansible/files/):"
cat "$RUNNER_HOME/.ssh/id_ed25519.pub"
echo "== This LXC's IP (put this in ALLOW_FROM in bootstrap-ssh.sh):"
hostname -I | awk '{print $1}'
