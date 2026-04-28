#!/usr/bin/env bash
# maillayer self-host installer.
#
#   curl -fsSL https://install.maillayer.com/install.sh | sudo bash
#
# Or for paranoid users:
#   curl -fsSL https://install.maillayer.com/install.sh -o install.sh
#   less install.sh
#   sudo bash install.sh
#
# Override defaults via env vars (passed before the curl):
#   MAILLAYER_DIR=/opt/maillayer        install root
#   MAILLAYER_PORT=3000                 host port
#   MAILLAYER_URL=https://...           public URL (optional, used for tracking links)
#   MAILLAYER_IMAGE=ghcr.io/owner/repo:1   override image tag
#
# This file lives in the app repo as the source of truth. The public
# install.sh URL serves a copy from a separate public installer repo (the
# script references the public Docker image only — no proprietary code).

set -euo pipefail

INSTALL_DIR="${MAILLAYER_DIR:-/opt/maillayer}"
PORT="${MAILLAYER_PORT:-3000}"
APP_URL="${MAILLAYER_URL:-}"
IMAGE="${MAILLAYER_IMAGE:-ghcr.io/mddanishyusuf/maillayer-pro:1}"

red()    { printf "\033[0;31m%s\033[0m\n" "$*"; }
green()  { printf "\033[0;32m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

require_root() {
  if [ "$(id -u)" != "0" ]; then
    red "Run as root (use sudo)."
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    red "Docker is not installed."
    echo "  Install it first: curl -fsSL https://get.docker.com | sudo sh"
    exit 1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    red "Docker Compose v2 is required."
    echo "  Install the docker-compose-plugin package, or upgrade Docker."
    exit 1
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

write_compose() {
  bold "[2/4] Writing docker-compose.yml…"
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

volumes:
  maillayer-data:
EOF
}

start() {
  bold "[3/4] Pulling image + starting…"
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
  mkdir -p "$INSTALL_DIR"
  write_env
  write_compose
  start
  wait_healthy
}

main "$@"
