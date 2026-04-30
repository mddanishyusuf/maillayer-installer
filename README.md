# maillayer-installer

One-line installer for [maillayer](https://github.com/mddanishyusuf/maillayer-pro) — a self-hosted email marketing platform.

## Install on any Linux VPS

```sh
curl -fsSL https://install.maillayer.com/install.sh | sudo bash
```

That's it — even on a fresh box. If Docker isn't installed, the script will install it for you using Docker Inc's official `get.docker.com` installer. To skip the auto-install (e.g. you manage Docker yourself), set `MAILLAYER_NO_AUTO_DOCKER=1`.

The script:

1. Auto-installs Docker + Docker Compose v2 if they aren't already present.
2. Checks that ports `80`, `443`, and `8024` are free on the host.
3. Generates a unique `AUTH_SECRET` (saved at `/opt/maillayer/.env`, mode 600).
4. Writes a 2-service `docker-compose.yml` (Caddy + Maillayer) and a tiny Caddy init config.
5. Pulls the public Docker image `ghcr.io/mddanishyusuf/maillayer-pro:1` and `caddy:2-alpine`.
6. Starts both containers with managed volumes, waits for `/api/health`, prints the URL.

## Adding a custom domain

The bundled Caddy sidecar is **wired up but inert at install time** — it listens on 80/443 with an empty config and waits for you to add a domain through the dashboard.

After install, sign in at `http://<your-server-ip>:8024` and go to **Settings → Domain**:

1. Enter your domain (e.g. `mail.example.com`) and a contact email.
2. Make sure an A record for that domain points at this server's public IP.
3. Click **Save & request certificate**.

Caddy issues a Let's Encrypt cert in the background (typically 30–60s). The page polls and flips the status pill from **Issuing cert…** to **Live** when the cert is active. You're done — `https://mail.example.com` now reverse-proxies to Maillayer.

You can change or remove the domain at any time from the same page.

## Skipping the bundled Caddy

If you already run a reverse proxy (nginx, Cloudflare Tunnel, Traefik, etc.), set `MAILLAYER_NO_CADDY=1` to install Maillayer alone — single-service compose, port `8024` only:

```sh
MAILLAYER_NO_CADDY=1 \
  curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash
```

In that mode the Settings → Domain page renders an "Managed externally" notice instead of the form — point your existing proxy at the Maillayer container's mapped port and set `APP_URL` in `/opt/maillayer/.env` to your public URL so tracking links resolve correctly.

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
| `MAILLAYER_PORT` | `8024` | Local-IP dashboard port (always exposed for ssh-tunnel access) |
| `MAILLAYER_URL` | (empty) | Public URL — set this if you proxy externally (`MAILLAYER_NO_CADDY=1` mode) |
| `MAILLAYER_IMAGE` | `ghcr.io/mddanishyusuf/maillayer-pro:1` | Image tag (pin to `:v1.2.0` for a fixed version) |
| `MAILLAYER_NO_CADDY` | `0` | Set to `1` to skip the bundled Caddy sidecar — bring your own reverse proxy |
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
- `/opt/maillayer/docker-compose.yml` — the 2-service definition (Caddy + Maillayer), or single-service if `MAILLAYER_NO_CADDY=1`.
- `/opt/maillayer/caddy-init.json` — minimal Caddy startup config (admin endpoint binding only). Maillayer pushes the real config via the admin API.
- Docker named volumes:
  - `maillayer_maillayer-data` — SQLite database, nightly backups, encryption key.
  - `maillayer_caddy-data` — issued certs, ACME state.
  - `maillayer_caddy-config` — Caddy's autosave (current effective config).

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
