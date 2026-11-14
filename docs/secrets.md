# Secrets

## Rules

- No secret is ever committed. `.gitignore` blocks `.env`, `stack.env`, keys and certs.
- Stack secrets live in **Portainer stack variables**, and a copy goes in **Vaultwarden** (a
  "Homelab" folder) so stacks can be rebuilt if Portainer is lost.
- Host and Ansible secrets will live in **Ansible Vault** once Ansible is added.
- Anything that was ever committed is considered leaked and gets rotated.

## Known leaks in the old repos

The old `cloudflare-tunnels` repo has 22 tunnel tokens in its Git history. The fix is to delete
those tunnels after moving to the single `homelab` tunnel ([cloudflare.md](cloudflare.md)), which
invalidates every old token. Then archive or delete the old repo. **Never mirror the old repos
anywhere.**

The old mealie and paperless repos had default DB passwords (`mealie`, `paperless`). Those are
only reachable on the Docker network, so the risk is low, but rotate them anyway.

## Rotating a Postgres password (mealie / paperless)

`POSTGRES_PASSWORD` is only read when the database is first created. Changing the variable alone
breaks the app. Do it in this order:

```bash
# 1. Change the password inside the database (example: mealie)
docker exec -it mealie-postgres psql -U mealie -d mealie \
  -c "ALTER USER mealie WITH PASSWORD 'NEW_LONG_RANDOM_PASSWORD';"

# Paperless equivalent (container name from `docker ps`):
# docker exec -it <paperless-db> psql -U paperless -d paperless -c "ALTER USER paperless WITH PASSWORD '...';"
```

2. Update `MEALIE_DB_PASSWORD` / `PAPERLESS_DB_PASSWORD` in Portainer → **Update the stack**.

Generate passwords with `openssl rand -base64 32`.
