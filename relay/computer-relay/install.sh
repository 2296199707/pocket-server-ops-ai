#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  printf '%s\n' 'run this installer as root' >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || {
  printf '%s\n' 'curl is required' >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || {
  printf '%s\n' 'tar is required' >&2
  exit 1
}

source_archive="${RELAY_SOURCE_ARCHIVE_URL:-https://github.com/2296199707/pocket-server-ops-ai/archive/refs/heads/beta.tar.gz}"
source_dir="$(mktemp -d "${TMPDIR:-/tmp}/pocket-server-ops.XXXXXX")"

cleanup() {
  rm -rf -- "$source_dir"
}
trap cleanup EXIT

curl -fsSL --retry 3 --retry-delay 1 "$source_archive" -o "$source_dir/source.tar.gz"
tar -xzf "$source_dir/source.tar.gz" -C "$source_dir"
project_dir="$(find "$source_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [ -z "$project_dir" ] || [ ! -f "$project_dir/relay/computer-relay/deploy.sh" ]; then
  printf '%s\n' 'PocketServerOps source archive has an unexpected layout' >&2
  exit 1
fi

bash "$project_dir/relay/computer-relay/deploy.sh"
