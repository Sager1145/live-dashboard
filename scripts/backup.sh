#!/bin/sh
set -eu
: "${DATABASE_URL:?DATABASE_URL is required}"
backup_dir=${1:?Usage: backup.sh /absolute/backup-directory}
mkdir -p "$backup_dir"
backup_path="$backup_dir/livedash-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-owner --file="$backup_path" "$DATABASE_URL"
pg_restore --list "$backup_path" >/dev/null
printf '%s\n' "$backup_path"
