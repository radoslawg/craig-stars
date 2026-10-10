# Running craig-stars in Docker / Portainer

This fork adds a production Docker image that serves the whole game from one container:

| Piece | Where |
|---|---|
| Web UI + API | port **8080** (Caddy serves the SvelteKit build, proxies `/api/*` to the Go backend) |
| Game data (SQLite DB + `config/config.yaml`) | volume mounted at **`/app/data`** |
| First login | **admin / admin**. Change the password straight away |

## 1. Build the image with GitHub Actions

`.github/workflows/docker-image.yml` builds and pushes on every push to `develop`, on `v*` tags, and when you run it by hand (Actions → *Docker image* → *Run workflow*).

* Images go to `ghcr.io/<your-github-user>/craig-stars` with tags `latest`, `develop`, `sha-xxxxxxx`.
* GHCR packages start out **private**. Either make the package public (GitHub → your profile → Packages → craig-stars → Package settings) or add GHCR as a registry in Portainer (Registries → Add → Custom, `ghcr.io`, your GitHub username, and a PAT with the `read:packages` scope).
* **Also push to your own registry (optional):** add the repository *variable* `REGISTRY_IMAGE` (e.g. `registry.example.com/games/craig-stars`) and the *secrets* `REGISTRY_USERNAME` / `REGISTRY_PASSWORD`.
* **ARM host (Raspberry Pi etc.):** set the repository variable `PLATFORMS` to `linux/amd64,linux/arm64`. The arm64 backend builds under emulation, so the build is slower.

To pick up upstream changes, click **Sync fork** on GitHub. That push to `develop` rebuilds the image. In Portainer, pull and redeploy the stack, or turn on the stack's automatic updates/webhook.

## 2. Deploy in Portainer

Stacks → Add stack → Web editor → paste `docker/docker-compose.yml`, change the image owner and the environment variables, then Deploy.

| Variable | Default | Meaning |
|---|---|---|
| `CS_PUBLIC_URL` | `http://localhost:8080` | URL players use to reach the game (invite links, OAuth redirects) |
| `CS_SECURE_COOKIE` | `false` | set `true` when the game is served over HTTPS |
| `CS_AUTH_SECRET` | random, stored in config.yaml | optional: override the JWT signing secret |
| `PUID` / `PGID` | `1000` | owner of the files in `/app/data` |

On first start the container writes `/app/data/config/config.yaml` with random secrets. You can edit it to enable Discord login, for example (see `config/config.go` for the keys).

### Behind a reverse proxy (Nginx Proxy Manager, Traefik, Caddy…)

Point the proxy at `http://<host>:8080`, set `CS_PUBLIC_URL=https://stars.example.com` and `CS_SECURE_COOKIE=true`.

## Build locally

```bash
docker build -t craig-stars .
docker run -d -p 8080:8080 -v craig-stars-data:/app/data craig-stars
```

## Backups

Back up the `craig-stars-data` volume. The game state is `data.db` (SQLite) plus `config/config.yaml`.
