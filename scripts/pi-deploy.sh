#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
env_file="$root/infra/pi.env"
configure=false
check=false
for arg in "$@"; do
  case "$arg" in
    --configure) configure=true ;;
    --check) check=true ;;
    *) echo "Usage: git deploy-pi [--configure] [--check]" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != Linux || "$(uname -m)" != aarch64 ]]; then
  echo "A 64-bit Raspberry Pi OS (aarch64) host is required." >&2
  exit 1
fi
for command_name in git docker openssl ip curl; do
  command -v "$command_name" >/dev/null || {
    echo "Missing $command_name on the Pi." >&2
    exit 1
  }
done
docker_cmd=(docker)
if ! docker info >/dev/null 2>&1; then
  docker_cmd=(sudo docker)
fi
"${docker_cmd[@]}" compose version >/dev/null
git config --local alias.deploy-pi '!scripts/pi-deploy.sh'

if [[ ! -f "$env_file" ]]; then
  umask 077
  cat > "$env_file" <<EOF
POSTGRES_PASSWORD=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 32)
API_BIND_IP=127.0.0.1
API_PORT=3000
EOF
  echo "Created private configuration: $env_file"
  echo "Admin password (ADMIN_TOKEN) is in that file; keep it private."
fi
chmod 600 "$env_file"

network_choices="127.0.0.1"
while IFS= read -r address; do
  [[ -z "$address" ]] && continue
  network_choices+=",$address"
done < <(ip -o -4 addr show scope global | awk '{print $4}' | cut -d/ -f1)
if grep -q '^API_NETWORK_CHOICES=' "$env_file"; then
  sed -i "s/^API_NETWORK_CHOICES=.*/API_NETWORK_CHOICES=$network_choices/" "$env_file"
else
  printf 'API_NETWORK_CHOICES=%s\n' "$network_choices" >> "$env_file"
fi

if $configure; then
  echo "Available IPv4 addresses:"
  ip -o -4 addr show scope global 2>/dev/null || true
  read -r -p "API bind IPv4 (127.0.0.1 for SSH tunnel): " selected_ip
  if [[ ! "$selected_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Enter a numeric IPv4 address." >&2
    exit 2
  fi
  if [[ "$selected_ip" != 127.0.0.1 ]] && ! ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$selected_ip"; then
    echo "The selected IPv4 address is not assigned to this Pi." >&2
    exit 2
  fi
  sed -i "s/^API_BIND_IP=.*/API_BIND_IP=$selected_ip/" "$env_file"
  "${docker_cmd[@]}" compose --env-file "$env_file" -f infra/compose.yaml exec -T db psql -U livedash -d livedash -c "INSERT INTO app_settings(key,value) VALUES('preferred_bind_ip','\"$selected_ip\"'::jsonb) ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value,updated_at=now()" >/dev/null 2>&1 || true
fi

if $check; then
  "${docker_cmd[@]}" compose --env-file "$env_file" -f infra/compose.yaml config --quiet
  echo "Compose configuration is valid."
  exit 0
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Tracked local changes exist; refusing to update the Pi checkout." >&2
  exit 1
fi
git fetch origin main
git merge --ff-only origin/main
preferred_ip="$("${docker_cmd[@]}" compose --env-file "$env_file" -f infra/compose.yaml exec -T db psql -U livedash -d livedash -Atqc "SELECT value #>> '{}' FROM app_settings WHERE key='preferred_bind_ip'" 2>/dev/null || true)"
if [[ -n "$preferred_ip" ]]; then
  if [[ ",$network_choices," != *",$preferred_ip,"* ]]; then
    echo "Saved network address $preferred_ip is unavailable; select a current address in the GUI or with --configure." >&2
    exit 1
  fi
  sed -i "s/^API_BIND_IP=.*/API_BIND_IP=$preferred_ip/" "$env_file"
fi
"${docker_cmd[@]}" compose --env-file "$env_file" -f infra/compose.yaml up -d --build --remove-orphans

bind_ip="$(sed -n 's/^API_BIND_IP=//p' "$env_file")"
api_port="$(sed -n 's/^API_PORT=//p' "$env_file")"
healthy=false
for _ in {1..30}; do
  if curl --noproxy '*' -fsS "http://$bind_ip:$api_port/health" >/dev/null; then
    healthy=true
    break
  fi
  sleep 2
done
if ! $healthy; then
  "${docker_cmd[@]}" compose --env-file "$env_file" -f infra/compose.yaml ps
  echo "API health check did not pass." >&2
  exit 1
fi
echo "API: http://$bind_ip:$api_port/health"
echo "Admin GUI: http://$bind_ip:$api_port/admin"
echo "For a loopback bind, use: ssh -L $api_port:127.0.0.1:$api_port <pi-user>@<pi-host>"
