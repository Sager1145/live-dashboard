#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux || "$(uname -m)" != aarch64 ]]; then
  echo "This installer requires 64-bit Raspberry Pi OS on aarch64." >&2
  exit 1
fi

as_root=()
if [[ "$(id -u)" != 0 ]]; then
  command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }
  as_root=(sudo)
fi

if ! command -v git >/dev/null || ! command -v openssl >/dev/null || ! command -v ip >/dev/null; then
  "${as_root[@]}" apt-get update
  "${as_root[@]}" apt-get install -y git openssl iproute2 ca-certificates curl
fi

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  installer="$(mktemp)"
  trap 'rm -f "$installer"' EXIT
  curl -fsSL https://get.docker.com -o "$installer"
  "${as_root[@]}" sh "$installer"
fi
if ! "${as_root[@]}" docker info >/dev/null 2>&1; then
  "${as_root[@]}" systemctl enable --now docker
fi

repo="$HOME/live-dashboard"
if [[ ! -d "$repo/.git" ]]; then
  if [[ -e "$repo" ]]; then
    echo "$repo exists but is not a Git checkout." >&2
    exit 1
  fi
  git clone https://github.com/Sager1145/live-dashboard.git "$repo"
fi
"$repo/scripts/pi-deploy.sh" "$@"
