# Secrets

## Rules

- **No secret is ever committed.** `.gitignore` blocks `.env`, `stack.env`, keys and certs, and the
  `lint` workflow fails if one gets committed anyway (tunnel tokens, private keys, env files).
- **Every secret has a copy in Vaultwarden**, so anything can be rebuilt if a host is lost.
- **Anything that was ever committed is treated as leaked** and gets rotated.

## Where each kind of secret lives

| Secret | Lives in | Used by |
|---|---|---|
| Docker stack secrets (DB passwords, API tokens, tunnel token) | Portainer stack variables | `${VAR}` in each `compose.yaml` (see each stack's `.env.example`) |
| Immich DB password and paths | `.env` on the Immich VM only | docker compose on the VM. Ansible only ever changes its `IMMICH_VERSION` line |
| Admin + break-glass password hashes, break-glass account name | `/ansible_config/secrets.yml` on the Ansible LXC (mode 600) | `users.yml` |
| Ansible SSH private key | `/ansible_config/.ssh/` on the Ansible LXC, never copied anywhere | every playbook |
| Personal SSH keys | Vaultwarden, served by the Bitwarden desktop app's SSH agent | SSH logins as the admin account |
| Renovate token, optional GitHub token | Gitea Actions secrets | `renovate.yml` |

`/ansible_config` is on the Ansible LXC's own disk, so PBS backs it up with the LXC.

## Rotating a Postgres password (mealie / paperless)

`POSTGRES_PASSWORD` is only read when the database is first created, so changing the variable alone
breaks the app. Do it in this order:

```bash
# 1. Change the password inside the database (example: mealie)
docker exec -it <mealie-db-container> psql -U mealie -d mealie \
  -c "ALTER USER mealie WITH PASSWORD 'NEW_LONG_RANDOM_PASSWORD';"
```

2. Update the stack's password variable in Portainer → **Update the stack**.

Generate passwords with `openssl rand -base64 32`, or in Vaultwarden.

## Rotating the admin or break-glass password

On the Ansible LXC, as the `runner` user: `openssl passwd -6`, replace the hash in
`/ansible_config/secrets.yml`, then run the **users** playbook. Check the hash first with
`openssl passwd -6 -salt <salt from the hash>`: it must print the same hash. Never paste a hash
anywhere.
