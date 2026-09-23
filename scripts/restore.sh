#!/bin/sh
set -eu
: "${RESTORE_DATABASE_URL:?Use a new empty database for RESTORE_DATABASE_URL}"
backup_path=${1:?Usage: restore.sh /absolute/backup.dump}
pg_restore --no-owner --exit-on-error --dbname="$RESTORE_DATABASE_URL" "$backup_path"
psql "$RESTORE_DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE notification_deliveries SET status='cancelled' WHERE status IN ('pending','retry','sending');"
printf '%s\n' 'Restore complete. Keep NOTIFICATIONS_ENABLED=false until delivery history and subscription state have been reconciled.'
