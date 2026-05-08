#!/usr/bin/env bash
# maillayer self-host installer.
#
#   curl -fsSL https://install.maillayer.com/install.sh | sudo bash
#
# By default the installer ships a small Caddy sidecar alongside the
# maillayer container so you can point a custom domain at this server and
# get auto-issued HTTPS — no DNS or cert work on your side beyond pointing
# the A record. Add the domain in the dashboard at:
#
#   Settings → Domain
#
# Don't want a managed reverse proxy? Set MAILLAYER_NO_CADDY=1 and the
# installer skips Caddy; bring your own nginx / Traefik / Cloudflare Tunnel.
#
# Or for paranoid users:
#   curl -fsSL https://install.maillayer.com/install.sh -o install.sh
#   less install.sh
#   sudo bash install.sh
#
# Override defaults via env vars (passed before the curl):
#   MAILLAYER_DIR=/opt/maillayer        install root
#   MAILLAYER_PORT=8024                 dashboard host port (always exposed for local access)
#   MAILLAYER_URL=https://...           public URL — set this if you proxy externally
#   MAILLAYER_IMAGE=ghcr.io/owner/repo:1   override image tag
#   MAILLAYER_NO_CADDY=1                skip the bundled Caddy sidecar (manage HTTPS yourself)
#   MAILLAYER_NO_AUTO_DOCKER=1          do NOT auto-install Docker if missing (default: auto-install)
#
# This file lives in the app repo as the source of truth. The public
# install.sh URL serves a copy from a separate public installer repo (the
# script references the public Docker image only — no proprietary code).

set -euo pipefail

INSTALL_DIR="${MAILLAYER_DIR:-/opt/maillayer}"
PORT="${MAILLAYER_PORT:-8024}"
APP_URL="${MAILLAYER_URL:-}"
IMAGE="${MAILLAYER_IMAGE:-ghcr.io/mddanishyusuf/maillayer-pro:1}"
NO_CADDY="${MAILLAYER_NO_CADDY:-0}"

# Split $IMAGE into base + tag so the container can pass them to the
# Docker daemon at self-update time (POST /images/create takes them
# separately). Falls back to ":1" if the operator passed an untagged
# image — that's our default rolling tag.
IMAGE_BASE="${IMAGE%:*}"
IMAGE_TAG="${IMAGE##*:}"
if [ "$IMAGE_BASE" = "$IMAGE_TAG" ]; then
  IMAGE_TAG="1"
fi

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    red "Run as root (use sudo)."
    exit 1
  fi
}

apt_locked() {
  # Returns 0 if any of the standard apt/dpkg locks are currently held.
  # Used to detect cloud-init / unattended-upgrades running in the
  # background on a freshly provisioned VPS — a very common cause of
  # `Could not get lock /var/lib/apt/lists/lock` from get.docker.com.
  local f
  for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock; do
    [ -f "$f" ] || continue
    if command -v flock >/dev/null 2>&1; then
      flock -n "$f" -c true 2>/dev/null || return 0
    elif command -v fuser >/dev/null 2>&1; then
      fuser "$f" >/dev/null 2>&1 && return 0
    fi
  done
  return 1
}

wait_for_apt() {
  apt_locked || return 0
  bold "Another apt/dpkg process is running (likely cloud-init or unattended-upgrades on a fresh VPS)."
  echo "  Waiting up to 5 min for it to finish before running the Docker installer…"
  local i
  for i in $(seq 1 60); do
    sleep 5
    if ! apt_locked; then
      echo "  apt is free. Continuing."
      return 0
    fi
  done
  red "apt is still locked after 5 min."
  echo "  See what's holding it: ps aux | grep -E 'apt|dpkg|unattended-upgrade'"
  echo "  Wait for that process to finish, then re-run this script."
  exit 1
}

install_docker() {
  bold "Docker not found — auto-installing via https://get.docker.com…"
  echo "  This is Docker Inc's official installer. Takes ~60s on a typical VPS"
  echo "  and installs Docker Engine + the Compose v2 plugin."
  echo "  To skip and install Docker yourself, re-run with:"
  echo "    MAILLAYER_NO_AUTO_DOCKER=1 curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash"
  echo
  wait_for_apt
  if ! curl -fsSL https://get.docker.com | sh; then
    red "Docker auto-install failed."
    echo "  Install manually following https://docs.docker.com/engine/install/"
    echo "  then re-run this script."
    exit 1
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [ "${MAILLAYER_NO_AUTO_DOCKER:-0}" = "1" ]; then
      red "Docker is not installed (and MAILLAYER_NO_AUTO_DOCKER=1 disabled auto-install)."
      echo "  Install it first: curl -fsSL https://get.docker.com | sudo sh"
      exit 1
    fi
    install_docker
    if ! command -v docker >/dev/null 2>&1; then
      red "Docker auto-install completed but 'docker' is still not on PATH."
      echo "  Try logging out and back in, or run:  hash -r  &&  command -v docker"
      exit 1
    fi
  fi
  if ! docker compose version >/dev/null 2>&1; then
    red "Docker Compose v2 is required."
    echo "  Install the docker-compose-plugin package, or upgrade Docker."
    echo "  On Debian/Ubuntu: apt-get install -y docker-compose-plugin"
    exit 1
  fi
}

# Returns 0 (true) if `port` is already bound on the host.
# Uses ss when available, falls back to netstat. If neither is present
# (very minimal images), skip the check rather than block install.
port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH "sport = :${port}" 2>/dev/null | grep -q . && return 0
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" && return 0
    return 1
  fi
  return 1
}

require_ports_free() {
  # On an upgrade, our own caddy + maillayer containers are holding the
  # ports we'd otherwise complain about. Detect that and skip the check —
  # the upcoming `compose up --force-recreate` will recycle them in
  # place. Fresh installs still get the full collision check.
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "  (existing install detected at $INSTALL_DIR — skipping port-collision check)"
    return 0
  fi

  if [ "$NO_CADDY" != "1" ]; then
    # Caddy needs 80 + 443. The maillayer container exposes PORT for the
    # local-IP dashboard regardless.
    for p in 80 443 "$PORT"; do
      if port_in_use "$p"; then
        red "Port $p is already in use on this host."
        if [ "$p" = "80" ] || [ "$p" = "443" ]; then
          echo "  The bundled Caddy sidecar binds 80 + 443 for HTTPS."
          echo "  If you'd rather manage your own reverse proxy, re-run with:"
          echo "    MAILLAYER_NO_CADDY=1 curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash"
        else
          echo "  Re-run with a different port:"
          echo "    MAILLAYER_PORT=8025 curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash"
        fi
        exit 1
      fi
    done
  else
    if port_in_use "$PORT"; then
      red "Port $PORT is already in use on this host."
      echo "  Re-run with a different port, e.g.:"
      echo "    MAILLAYER_PORT=8025 curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash"
      exit 1
    fi
  fi
}

write_env() {
  if [ -f "$INSTALL_DIR/.env" ] && grep -q "^AUTH_SECRET=" "$INSTALL_DIR/.env"; then
    bold "[1/4] Existing .env found — preserving AUTH_SECRET."
    return
  fi
  bold "[1/4] Generating AUTH_SECRET…"
  local secret
  secret=$(openssl rand -base64 48 | tr -d '\n')
  install -m 600 /dev/null "$INSTALL_DIR/.env"
  cat > "$INSTALL_DIR/.env" <<EOF
AUTH_SECRET=$secret
APP_URL=$APP_URL
EOF
  chmod 600 "$INSTALL_DIR/.env"
}

# Caddy starts with this minimal init config — just binds the admin API
# to the docker network so the maillayer container can push the real
# config (placeholder when no domain, reverse proxy when one is set).
write_caddy_init() {
  # `origins` is required because Caddy's admin endpoint enforces an
  # allow-list against the request's Origin header. We use the full
  # `http://host:port` form — empirically that's the one Caddy actually
  # matches against an incoming Origin: http://caddy:2019.
  cat > "$INSTALL_DIR/caddy-init.json" <<'EOF'
{
  "admin": {
    "listen": "0.0.0.0:2019",
    "origins": ["http://caddy:2019", "http://localhost:2019", "http://0.0.0.0:2019"]
  }
}
EOF
}

write_compose() {
  if [ "$NO_CADDY" = "1" ]; then
    bold "[2/4] Writing docker-compose.yml (single-service: no Caddy)…"
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  maillayer:
    image: $IMAGE
    restart: unless-stopped
    ports:
      - "$PORT:3000"
    volumes:
      - maillayer-data:/app/data
      # Lets the dashboard's "Update now" button pull the new image and
      # restart this container without the operator SSHing in. Mounted
      # rw so the container can issue restart commands. Comment this
      # line out if your security model forbids it; the dashboard will
      # fall back to the manual copy-the-command flow.
      - /var/run/docker.sock:/var/run/docker.sock
    env_file:
      - .env
    environment:
      - MAILLAYER_NO_CADDY=1
      - MAILLAYER_PULL_IMAGE=$IMAGE_BASE
      - MAILLAYER_PULL_TAG=$IMAGE_TAG

volumes:
  maillayer-data:
EOF
  else
    bold "[2/4] Writing docker-compose.yml + Caddy init…"
    write_caddy_init
    cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    # Start with the minimal init config; maillayer's boot hook posts the
    # real config (placeholder or domain) to the admin API at :2019.
    command: ["caddy", "run", "--config", "/etc/caddy/init.json"]
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy-init.json:/etc/caddy/init.json:ro
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - maillayer-net

  maillayer:
    image: $IMAGE
    restart: unless-stopped
    ports:
      - "$PORT:3000"
    volumes:
      - maillayer-data:/app/data
      # See note above re: dashboard self-update via Docker socket.
      - /var/run/docker.sock:/var/run/docker.sock
    env_file:
      - .env
    environment:
      - CADDY_ADMIN_URL=http://caddy:2019
      - MAILLAYER_PULL_IMAGE=$IMAGE_BASE
      - MAILLAYER_PULL_TAG=$IMAGE_TAG
    networks:
      - maillayer-net
    depends_on:
      - caddy

volumes:
  maillayer-data:
  caddy-data:
  caddy-config:

networks:
  maillayer-net:
EOF
  fi
}

start() {
  bold "[3/4] Pulling images + starting…"
  # --force-recreate ensures bind-mounted file changes (caddy-init.json,
  # docker-compose.yml) actually get picked up on a re-run of the
  # installer — `up -d` alone won't recreate a container if only the
  # mounted file content changed.
  ( cd "$INSTALL_DIR" && docker compose pull && docker compose up -d --force-recreate )
}

wait_healthy() {
  bold "[4/4] Waiting for healthcheck…"
  local i
  for i in $(seq 1 30); do
    if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
      echo
      local host_ip
      host_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
      green "✓ maillayer is up at http://${host_ip}:$PORT"
      echo "  Open the URL in a browser and sign up to create the owner account."
      if [ "$NO_CADDY" != "1" ]; then
        echo
        echo "  To attach a custom domain with auto-HTTPS:"
        echo "    1. Point an A record for the domain at this server's public IP."
        echo "    2. Open Settings → Domain in the dashboard and enter the domain."
        echo "    3. Caddy issues a Let's Encrypt cert in 30–60s. Done."
      fi
      echo "  Config + secret: $INSTALL_DIR"
      echo
      echo "Useful commands:"
      echo "  Logs:    docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
      echo "  Update:  cd $INSTALL_DIR && docker compose pull && docker compose up -d"
      echo "  Stop:    cd $INSTALL_DIR && docker compose down"
      exit 0
    fi
    sleep 2
  done
  red "Container started, but healthcheck didn't respond in 60s."
  echo "Check logs: docker compose -f $INSTALL_DIR/docker-compose.yml logs"
  exit 1
}

main() {
  require_root
  require_docker
  require_ports_free
  mkdir -p "$INSTALL_DIR"
  write_env
  write_compose
  start
  wait_healthy
}

main "$@"
