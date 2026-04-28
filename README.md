# maillayer-installer

One-line installer for [maillayer](https://github.com/mddanishyusuf/maillayer-pro) — a self-hosted email marketing platform.

## Install on any Linux VPS

Requires Docker + Docker Compose v2 already installed (`curl -fsSL https://get.docker.com | sudo sh` if not).

```sh
curl -fsSL https://install.maillayer.com/install.sh | sudo bash
```

The script:

1. Generates a unique `AUTH_SECRET` (saved at `/opt/maillayer/.env`, mode 600).
2. Pulls the public Docker image `ghcr.io/mddanishyusuf/maillayer-pro:1`.
3. Starts the service via Docker Compose with a managed volume for your data.
4. Waits for `/api/health` and prints the URL.

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

It does NOT install Docker itself, modify firewall rules, edit other system services, or make outbound calls beyond pulling the Docker image. Read [install.sh](install.sh) before running.

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
