#!/usr/bin/env bash
# cnpg-dump.sh — manual pg_dump rip cord for a CNPG cluster.
#
# Independent of volumeSnapshots / TrueNAS CSI. The CronJob versions in
# _lib/applications/<app>/overlays/dev/dump-cronjob.yaml inline the same
# logic for automation; this script is the human equivalent (one-shot dump
# from a workstation that has cluster access via the `kube` wrapper).
#
# Usage:
#   cnpg-dump.sh <namespace> <cluster-name> <database> <output-dir>
#
# Example:
#   cnpg-dump.sh freshrss freshrss-dev-cluster freshrss ./dumps
#
# Reads the superuser password from the cluster's superuser secret
# (postgres user). Connects to the -rw service. Writes
# <output-dir>/<cluster>-<database>-<timestamp>.dump (pg_dump custom format).
set -euo pipefail

NS="${1:?usage: cnpg-dump.sh <ns> <cluster> <db> <output-dir>}"
CLUSTER="${2:?missing <cluster>}"
DB="${3:?missing <db>}"
OUT_DIR="${4:?missing <output-dir>}"
mkdir -p "$OUT_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/${CLUSTER}-${DB}-${STAMP}.dump"

SUPERUSER_SECRET="$(kube dev -n "$NS" get cluster.postgresql.cnpg.io "$CLUSTER" -o jsonpath='{.spec.superuserSecret.name}')"
PGUSER="$(kube dev -n "$NS" get secret "$SUPERUSER_SECRET" -o jsonpath='{.data.username}' | base64 -d)"
PGPASSWORD="$(kube dev -n "$NS" get secret "$SUPERUSER_SECRET" -o jsonpath='{.data.password}' | base64 -d)"
export PGPASSWORD

echo "[cnpg-dump] $NS/$CLUSTER db=$DB -> $OUT"
# Run pg_dump inside an ephemeral pod in the cluster's namespace so we
# don't depend on a workstation-side postgres-client install.
kube dev -n "$NS" run "cnpg-dump-$STAMP" --rm -i --restart=Never \
  --image=ghcr.io/cloudnative-pg/postgresql:17.4-6 \
  --env="PGPASSWORD=$PGPASSWORD" \
  --command -- pg_dump \
    --host="${CLUSTER}-rw" \
    --port=5432 \
    --username="$PGUSER" \
    --dbname="$DB" \
    --format=custom \
    --no-owner \
    --no-acl \
  > "$OUT"

echo "[cnpg-dump] wrote $(wc -c < "$OUT") bytes to $OUT"
echo "[cnpg-dump] restore with: pg_restore --clean --if-exists --no-owner --no-acl -d <db> $OUT"
