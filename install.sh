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

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    red "Run as root (use sudo)."
    exit 1
  fi
}

install_docker() {
  bold "Docker not found — auto-installing via https://get.docker.com…"
  echo "  This is Docker Inc's official installer. Takes ~60s on a typical VPS"
  echo "  and installs Docker Engine + the Compose v2 plugin."
  echo "  To skip and install Docker yourself, re-run with:"
  echo "    MAILLAYER_NO_AUTO_DOCKER=1 curl -fsSL https://install.maillayer.com/install.sh | sudo -E bash"
  echo
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
  cat > "$INSTALL_DIR/caddy-init.json" <<'EOF'
{
  "admin": {
    "listen": "0.0.0.0:2019"
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
    env_file:
      - .env
    environment:
      - MAILLAYER_NO_CADDY=1

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
    env_file:
      - .env
    environment:
      - CADDY_ADMIN_URL=http://caddy:2019
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
  ( cd "$INSTALL_DIR" && docker compose pull && docker compose up -d )
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
