#!/usr/bin/env bash
set -euo pipefail

install_dir="${RELAY_INSTALL_DIR:-/www/pocket-server-ops-computer-relay}"
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

mkdir -p "$install_dir/data"
chmod 700 "$install_dir" "$install_dir/data"
chown -R 1000:1000 "$install_dir/data"
cp "$script_dir"/{Dockerfile,package.json,server.mjs,compose.yaml} "$install_dir/"
if [ ! -f "$install_dir/.env" ]; then
  umask 077
  printf 'RELAY_API_TOKEN=%s\nRELAY_PORT=8787\nRELAY_BIND=0.0.0.0\n' "$(openssl rand -hex 32)" > "$install_dir/.env"
fi
chmod 600 "$install_dir/.env"
cd "$install_dir"
docker compose up -d --build --remove-orphans
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$(sed -n 's/^RELAY_PORT=//p' .env)/v1/health" >/dev/null 2>&1; then
    printf 'Computer relay is healthy at %s:%s\n' "$(hostname -f 2>/dev/null || hostname)" "$(sed -n 's/^RELAY_PORT=//p' .env)"
    printf 'API token is stored in %s/.env\n' "$install_dir"
    exit 0
  fi
  sleep 2
done
printf '%s\n' 'relay did not become healthy; run docker compose logs' >&2
exit 1
