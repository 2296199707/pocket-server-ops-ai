#!/usr/bin/env bash
set -euo pipefail

install_dir="${RELAY_INSTALL_DIR:-/www/pocket-server-ops-computer-relay}"
relay_port="${RELAY_PORT:-8787}"
relay_bind="${RELAY_BIND:-127.0.0.1}"
compose_project="pocket-server-ops-computer-relay"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' 'run this installer as root' >&2
  exit 1
fi
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' 'Docker is required; install Docker Compose v2 first' >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  printf '%s\n' 'Docker Compose v2 is required' >&2
  exit 1
}
command -v openssl >/dev/null 2>&1 || {
  printf '%s\n' 'openssl is required' >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  printf '%s\n' 'curl is required' >&2
  exit 1
}

mkdir -p "$install_dir/data"
chmod 700 "$install_dir" "$install_dir/data"
chown -R 1000:1000 "$install_dir/data"
for file in Dockerfile package.json package-lock.json server.mjs compose.yaml; do
  cp "$script_dir/$file" "$install_dir/$file"
done
if [ ! -f "$install_dir/.env" ]; then
  umask 077
  printf 'RELAY_API_TOKEN=%s\nRELAY_PORT=%s\nRELAY_BIND=%s\n' \
    "$(openssl rand -hex 32)" "$relay_port" "$relay_bind" > "$install_dir/.env"
fi
chmod 600 "$install_dir/.env"
cd "$install_dir"
docker compose -p "$compose_project" up -d --build
health_port="$(sed -n 's/^RELAY_PORT=//p' .env | tail -n 1)"
health_port="${health_port:-8787}"
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${health_port}/v1/health" >/dev/null 2>&1; then
    printf 'Computer relay is healthy at 127.0.0.1:%s\n' "$health_port"
    printf 'API token is stored in %s/.env\n' "$install_dir"
    printf 'Add your existing HTTPS reverse proxy for the relay before using it remotely.\n'
    exit 0
  fi
  sleep 2
done
printf '%s\n' 'relay did not become healthy; run docker compose logs' >&2
exit 1
