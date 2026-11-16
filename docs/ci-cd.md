# CI/CD: how updates reach the hosts

```
new image released
   │
   ▼
Renovate (Gitea Actions, every 4h) ── opens PR: "Update vaultwarden/server to 1.37.6"
   │
   ▼
lint workflow ── compose config valid? every image pinned? no secrets?
   │
   ├── low-risk stack, minor/patch, release ≥ 3 days old ──► auto-merge
   └── everything else ──► waits for me to read the release notes and merge
   │
   ▼
main branch ── Portainer GitOps polling (5 min) ──► docker compose up -d on the host
            └─ Immich only: the ansible workflow ──► DB dump, deploy, health + version check
```

## Update policy (`renovate.json`)

| Auto-merge (minor/patch) | Always reviewed |
|---|---|
| cloudflared, homepage, tautulli, uptime-kuma, *arr stack (one grouped PR), audiobookshelf, gitea-runner, CI tooling | vaultwarden, paperless-ngx (+ gotenberg, tika), mealie, foundry-vtt, **Immich**, **every major version** |

**Locked (no PRs at all):** qBittorrent. Its tag is changed by hand.

- Postgres and Redis **major** updates are disabled. They need a dump/restore or `pg_upgrade`,
  not an image bump.
- Auto-merges wait until a release is 3 days old, so broken releases usually get pulled or fixed
  first.
- **Immich** major versions only get a PR once they're 7 days old. Its compose file is updated by hand from upstream, in the same PR as the version bump.
- The **Dependency Dashboard** issue in Gitea lists every pending and blocked update.

## Rolling back

Revert the merge commit in Gitea (or `git revert <sha>` and push). Portainer redeploys the
previous version within 5 minutes. Images that run database migrations (Paperless, Mealie,
Vaultwarden, Immich) may not run on the old version after a migration. For those, restore the LXC
from PBS, or for Immich, the pre-update dump ([ansible/README.md](../ansible/README.md#rolling-back-a-bad-upgrade)).

## One-time setup

### 1. Runner LXC on skynet

1. Create an **unprivileged Debian 13 LXC**: 2 cores, 2 GB RAM, 16 GB disk.
   Options → Features: **nesting = 1, keyctl = 1** (required for Docker inside an unprivileged LXC).
2. Install Docker and the Portainer agent the same way as your other LXCs, then add it to Portainer
   as a new environment (`skynet-runner`).

### 2. Gitea Actions

1. **Site Administration → Actions → Runners.** If that menu is missing, add this to `app.ini` and
   restart Gitea:
   ```ini
   [actions]
   ENABLED = true
   ```
2. **Create new runner** → copy the registration token.
3. Portainer → `skynet-runner` → add stack `stacks/skynet/gitea-runner/compose.yaml`, with
   `GITEA_RUNNER_REGISTRATION_TOKEN` set.
4. The runner should show as **Idle** under Site Administration → Actions → Runners.
5. `alex/homelab` → **Settings → Repository → Advanced settings**: tick **Actions** (and
   **Issues**, which the Dependency Dashboard needs).

### 3. Renovate bot account

1. Site Administration → User Accounts → **Create** user `renovate-bot`. Its email can be anything
   (e.g. `renovate-bot@noreply.failsafe.work`).
2. `alex/homelab` → Settings → **Collaborators** → add `renovate-bot` with **Write**.
3. Sign in as `renovate-bot` → Settings → Applications → **Generate token** with these scopes:
   - repository: **Read and Write**
   - issue: **Read and Write**
   - user: **Read**
   - organization: **Read**
4. `alex/homelab` → Settings → Actions → **Secrets**:
   - `RENOVATE_TOKEN`: the bot's token
   - `RENOVATE_GITHUB_COM_TOKEN` (optional, recommended): a GitHub fine-grained token with
     **public repositories read-only** access and no other permissions. It adds release notes to
     PRs and avoids GitHub rate limits.
5. Save both tokens in Vaultwarden.

### 4. Branch protection (makes auto-merge wait for CI)

Turn this on **after** the first lint run passes. Otherwise PRs can't merge at all.

`alex/homelab` → Settings → **Branches → Add rule**, for branch `main`:
- **Push:** Enable push (you can still push directly).
- **Status check:** enabled, pattern `lint / compose*`.
- **Required approvals:** 0, so Renovate can merge its own low-risk PRs.

### 5. First run

Actions tab → **renovate** → **Run workflow**. Within a few minutes you should see a
**Dependency Dashboard** issue and the first update PRs.
