# Ansible

Ansible keeps the operating system of every machine up to date. It runs on its own **Ansible LXC**
on skynet (the "control node"), which has a Gitea runner registered with the label `ansible`. The
`ansible` workflow sends its jobs there, and Ansible connects to each machine over SSH as a dedicated
`ansible` user.

```
Gitea (schedule / Run workflow) ──► Ansible LXC on skynet ──SSH──► every LXC, VM, Pi, Proxmox host
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
  bootstrap/
    setup-control-node.sh  one-time: turns a fresh LXC into the Ansible LXC
    bootstrap-ssh.sh       one-time per machine: creates the ansible user + authorizes the key
  known_hosts              host public keys, so Ansible can verify it's talking to the real machine
  requirements.txt / .yml  pinned Ansible + collection versions (Renovate keeps them current)
```

## When it runs

| Trigger | Playbook | Reboots? |
|---|---|---|
| Every Sunday 04:30 Pacific (05:30 in summer), after the PBS backups | `patch-guests` | No. The summary says `REBOOT NEEDED` where one is due |
| Actions → ansible → **Run workflow** | your choice | Only if you tick *allow_reboot* (guests only) |

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
ssh-keyscan -t ed25519 192.168.50.8 192.168.50.220 192.168.50.199 192.168.50.3 192.168.50.88 \
  192.168.50.151 192.168.50.246 192.168.50.81 192.168.50.106 192.168.50.124 192.168.50.2
```

Paste the output into `ansible/known_hosts` and commit it. Re-scan a host if you rebuild it.

### 5. Test

1. Actions → **ansible** → Run workflow → playbook **ping**. Every host should be green.
2. **patch-guests** with **check_mode** ticked: a preview of the updates, nothing applied.
3. **patch-guests** for real with **limit** `pis`.

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
```

Keep the single quotes: the hashes contain `$`. Store both passwords and the break-glass name in
Vaultwarden. The workflow loads this file automatically, and `users` refuses to run if anything is
missing or both passwords are the same.

### Order (don't skip the testing)

1. Run `users` with **check_mode**, then for real.
2. From the PC, on a few hosts: `ssh alex@192.168.50.81`, then `sudo -v`. Both must work.
3. Run `harden-ssh` with **limit** set to one host, then test `ssh alex@` and confirm `ssh root@` is
   refused.
4. Run `harden-ssh` on everything, with the Pis last (`limit: pis`). They have no web console, so
   a mistake there means plugging in a keyboard and monitor.

## Adding a machine

1. Run `bootstrap-ssh.sh self` on it (or `lxcs` on its Proxmox host).
2. Add it under the right group in `inventory/hosts.yml`.
3. Add its key to `known_hosts` (`ssh-keyscan -t ed25519 <ip>` on the Ansible LXC).

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
