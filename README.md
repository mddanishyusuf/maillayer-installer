# maillayer-installer

One-line installer for [maillayer](https://github.com/mddanishyusuf/maillayer-pro) — a self-hosted email marketing platform.

## Install on any Linux VPS

```sh
curl -fsSL https://install.maillayer.com/install.sh | sudo bash
```

That's it — even on a fresh box. If Docker isn't installed, the script will install it for you using Docker Inc's official `get.docker.com` installer. To skip the auto-install (e.g. you manage Docker yourself), set `MAILLAYER_NO_AUTO_DOCKER=1`.

The script:

1. Auto-installs Docker + Docker Compose v2 if they aren't already present.
2. Checks that the host port (default `8024`) is free.
3. Generates a unique `AUTH_SECRET` (saved at `/opt/maillayer/.env`, mode 600).
4. Pulls the public Docker image `ghcr.io/mddanishyusuf/maillayer-pro:1`.
5. Starts the service via Docker Compose with a managed volume for your data.
6. Waits for `/api/health` and prints the URL.

## Install with a custom domain + auto-TLS

Pass a domain and contact email to enable a built-in Caddy reverse proxy with Let's Encrypt:

```sh
MAILLAYER_DOMAIN=mail.example.com \
MAILLAYER_EMAIL=you@example.com \
  curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash
```

What this changes:

- A `caddy:2-alpine` container is added on ports 80 + 443. It auto-issues and renews a Let's Encrypt certificate for your domain.
- The maillayer container binds to `127.0.0.1:8024` (loopback only) — the only public ingress is Caddy.
- `APP_URL` is set to `https://<your-domain>` so tracking + unsubscribe links use the real URL.

DNS prerequisite: an A/AAAA record for the domain must already point at this host's public IP, otherwise ACME validation fails. The cert request happens in the background on first start (~30–60s).

### Prefer to read first?

```sh
curl -fsSL https://install.maillayer.com/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

### Override defaults

```sh
MAILLAYER_PORT=8080 \
MAILLAYER_URL=https://mail.example.com \
MAILLAYER_DIR=/var/lib/maillayer \
  curl -fsSL https://install.maillayer.com/install.sh | sudo bash
```

| Env var | Default | Purpose |
|---|---|---|
| `MAILLAYER_DIR` | `/opt/maillayer` | Install root |
| `MAILLAYER_PORT` | `8024` | Host port (loopback-only when `MAILLAYER_DOMAIN` is set) |
| `MAILLAYER_URL` | (empty) | Public URL — auto-set to `https://$MAILLAYER_DOMAIN` in domain mode |
| `MAILLAYER_IMAGE` | `ghcr.io/mddanishyusuf/maillayer-pro:1` | Image tag (pin to `:v1.1.0` for a fixed version) |
| `MAILLAYER_DOMAIN` | (empty) | Public domain — turns on Caddy reverse proxy |
| `MAILLAYER_EMAIL` | (empty) | ACME contact email — required when `MAILLAYER_DOMAIN` is set |
| `MAILLAYER_NO_AUTO_DOCKER` | `0` | Set to `1` to disable the Docker auto-install — useful if you manage Docker yourself |

## Maintenance

After install, manage with normal Docker Compose commands:

```sh
# Logs
docker compose -f /opt/maillayer/docker-compose.yml logs -f

# Update to the latest 1.x image
cd /opt/maillayer && docker compose pull && docker compose up -d

# Stop
cd /opt/maillayer && docker compose down
```

## What gets installed

- `/opt/maillayer/.env` — your `AUTH_SECRET` and any other operator-set env vars (mode 600).
- `/opt/maillayer/docker-compose.yml` — the service definition.
- A Docker named volume `maillayer_maillayer-data` — holds the SQLite database and nightly backups.

## Security note

`curl | sudo bash` runs a remote script as root. The script in this repo:

- Creates a config directory and writes a compose file.
- Pulls a public Docker image from GHCR.
- Generates a random secret via `openssl rand -base64 48`.
- Starts the container.

It does NOT modify firewall rules, edit other system services beyond Docker, or make outbound calls beyond pulling the Docker image and (if Docker is missing) Docker Inc's official `get.docker.com` installer. The Docker auto-install can be disabled with `MAILLAYER_NO_AUTO_DOCKER=1`. Read [install.sh](install.sh) before running.

## Backup

The encryption key in `/opt/maillayer/.env` (`AUTH_SECRET`) decrypts every stored Stripe / Firebase / Supabase / Airtable credential. Back it up alongside your SQLite DB.

```sh
# Quick offsite backup of secret + DB volume
tar czf maillayer-backup-$(date +%F).tar.gz \
  /opt/maillayer/.env \
  $(docker volume inspect maillayer_maillayer-data --format '{{ .Mountpoint }}')
```

## Source code

Image source: <https://github.com/mddanishyusuf/maillayer-pro> (private).
