#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --host USER@HOST --remote-dir /absolute/path --confirm-public-fixture" >&2
  exit 2
}

host=
remote_dir=
confirmed=false
while (($#)); do
  case "$1" in
    --host) host=${2:-}; shift 2 ;;
    --remote-dir) remote_dir=${2:-}; shift 2 ;;
    --confirm-public-fixture) confirmed=true; shift ;;
    *) usage ;;
  esac
done

[[ -n "$host" && "$remote_dir" == /* && "$confirmed" == true ]] || usage
[[ "$remote_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "remote directory may contain only letters, numbers, dot, underscore, slash, and hyphen" >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root/services/evidence-dashboard"

# The archive contains only the fixture-mode application and fabricated data.
# It deliberately excludes the repository, database credentials, and live-mode
# configuration. The remote compose file binds to loopback for the host proxy.
tar -C "$source_dir" \
  --exclude='.git' \
  --exclude='node_modules' \
  -czf - . | ssh -- "$host" "mkdir -p '$remote_dir' && tar -xzf - -C '$remote_dir'"

ssh -- "$host" "cd '$remote_dir' && docker compose -f compose.fixture.yaml up -d --build"
ssh -- "$host" "curl --fail --silent --show-error http://127.0.0.1:8080/lnd/api/health | grep -F '\"dataMode\":\"fixture\"' >/dev/null"

echo "OCI fixture dashboard deployed. Configure the existing HTTP proxy to preserve /lnd -> 127.0.0.1:8080."
