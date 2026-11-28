#!/usr/bin/env bash
# Nightly PostgreSQL/PostGIS custom-format backup of `dci_tailor_production` to S3.
# Run on the EC2 host via systemd timer or cron as root.
# S3 lifecycle rules expire `pgdump/` objects after 30 days; daily EBS snapshots provide a second layer.
set -euo pipefail

CONTAINER_NAME="${DCI_TAILOR_DB_CONTAINER:-dci-tailor-db}"
DB_NAME="${DCI_TAILOR_DB_NAME:-dci_tailor_production}"
LOCK_FILE="${DCI_TAILOR_BACKUP_LOCK:-/var/lock/dci-tailor-backup.lock}"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another dci-tailor PostgreSQL backup is already running (lock: $LOCK_FILE); exiting." >&2
  exit 1
fi

if [ -n "${AWS_REGION:-}" ]; then
  region="$AWS_REGION"
else
  token=$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
  region=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/region)
fi

bucket="${AWS_S3_BUCKET:-$(aws ssm get-parameter --region "$region" --name /dci-tailor/storage-bucket --query Parameter.Value --output text)}"
timestamp="$(date -u +%Y-%m-%dT%H%M%SZ)"
key="pgdump/dci-tailor-${timestamp}.dump"

# Write to a local temp file first so an interrupted dump is never uploaded as a truncated S3 object.
umask 077
dump_file="$(mktemp /var/tmp/dci-tailor-pgdump.XXXXXX)"
trap 'rm -f "$dump_file"' EXIT

# Read POSTGRES_USER and POSTGRES_PASSWORD inside the container environment so credentials never appear in host `ps`.
docker exec "$CONTAINER_NAME" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -Fc --no-owner --no-acl -U "$POSTGRES_USER" "$1"' sh "$DB_NAME" > "$dump_file"

if ! { [ -s "$dump_file" ] && docker exec -i "$CONTAINER_NAME" pg_restore --list < "$dump_file" >/dev/null; }; then
  echo "Backup verification failed: $dump_file is empty or failed pg_restore --list" >&2
  exit 1
fi

aws s3 cp "$dump_file" "s3://${bucket}/${key}" \
  --region "$region" \
  --sse AES256 \
  --only-show-errors

echo "Backup written to s3://${bucket}/${key} ($(wc -c < "$dump_file" | tr -d ' ') bytes)"
