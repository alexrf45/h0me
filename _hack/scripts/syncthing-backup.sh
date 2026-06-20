#!/usr/bin/env bash
#
# syncthing-backup.sh — manual Syncthing data-volume backup to anubis.
#
# Snapshots the TrueNAS zvol holding Syncthing's vault data, mounts the
# snapshot read-only on TrueNAS, then runs `restic backup` over SFTP to
# anubis. Designed to run from the local workstation, not in-cluster.
#
# Failure mode this guards against: TrueNAS pool death (backup is on a
# separate host) and accidental Syncthing-driven deletion (restic keeps
# history beyond what Syncthing's versioning offers).
#
# Prerequisites (one-time, manual):
#   1. SSH key for ${TRUENAS_USER}@${TRUENAS_HOST} loaded in your agent.
#   2. SSH key for ${ANUBIS_USER}@${ANUBIS_HOST} loaded in your agent.
#   3. ${ANUBIS_PATH} exists on anubis and is writable.
#   4. restic repo initialized: `restic -r sftp:${ANUBIS_USER}@${ANUBIS_HOST}:${ANUBIS_PATH} init`
#   5. RESTIC_PASSWORD_FILE exists locally (e.g. `op read 'op://Private/syncthing-restic/password' > ~/.config/restic/syncthing-dev.pwd`).
#   6. local: `restic` and `ssh` on PATH.
#
# Usage:
#   ./syncthing-backup.sh           # run a real backup
#   ./syncthing-backup.sh --dry-run # show what restic would back up

set -euo pipefail

# --- configuration ---------------------------------------------------------
TRUENAS_HOST="${TRUENAS_HOST:-192.168.20.106}"
TRUENAS_USER="${TRUENAS_USER:-truenas_admin}"
DATASET="${DATASET:-home-share/iscsi/k8s/dev/volumes/dev-syncthing-data}"

ANUBIS_HOST="${ANUBIS_HOST:-192.168.20.87}"
ANUBIS_USER="${ANUBIS_USER:-fr3d}"
ANUBIS_PATH="${ANUBIS_PATH:-/backups/syncthing-dev}"

RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${HOME}/.config/restic/syncthing-dev.pwd}"

KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="--dry-run"
fi
# ---------------------------------------------------------------------------

log() { printf '[syncthing-backup] %s\n' "$*" >&2; }

# Iscsi zvols hold a raw filesystem image, not a directly-mountable directory.
# To read files we clone the snapshot, then mount the resulting clone on the
# TrueNAS host (loop-back) read-only. The script reads files via SSH+tar so
# we don't have to NFS-export the clone.

TS="$(date +%Y%m%d-%H%M%S)"
SNAP="${DATASET}@manual-${TS}"
CLONE="${DATASET%/*}/_backup-clones/${DATASET##*/}-${TS}"
MNT="/mnt/_backup-mounts/${DATASET##*/}-${TS}"

cleanup() {
  local rc=$?
  log "cleanup (exit=${rc})"
  ssh -o BatchMode=yes "${TRUENAS_USER}@${TRUENAS_HOST}" "
    set -e
    if mountpoint -q '${MNT}'; then sudo umount '${MNT}'; fi
    if [ -d '${MNT}' ]; then sudo rmdir '${MNT}' || true; fi
    if zfs list -H '${CLONE}' >/dev/null 2>&1; then sudo zfs destroy '${CLONE}'; fi
    if zfs list -H -t snapshot '${SNAP}' >/dev/null 2>&1; then sudo zfs destroy '${SNAP}'; fi
  " || log "cleanup ssh failed (non-fatal)"
  exit "${rc}"
}
trap cleanup EXIT INT TERM

log "snapshot+clone+mount on ${TRUENAS_HOST}: ${SNAP}"
ssh -o BatchMode=yes "${TRUENAS_USER}@${TRUENAS_HOST}" "
  set -euo pipefail
  sudo zfs snapshot '${SNAP}'
  sudo zfs clone -o readonly=on '${SNAP}' '${CLONE}'
  sudo mkdir -p '${MNT}'
  ZVOL_DEV=\$(readlink -f '/dev/zvol/${CLONE}')
  sudo mount -o ro,norecovery \"\${ZVOL_DEV}\" '${MNT}'
"

log "running restic backup (this streams over SSH+tar)"
ssh -o BatchMode=yes "${TRUENAS_USER}@${TRUENAS_HOST}" "sudo tar -C '${MNT}' -cf - ." \
  | restic \
      --password-file "${RESTIC_PASSWORD_FILE}" \
      -r "sftp:${ANUBIS_USER}@${ANUBIS_HOST}:${ANUBIS_PATH}" \
      backup --stdin --stdin-filename "syncthing-data-${TS}.tar" \
      ${DRY_RUN}

if [[ -z "${DRY_RUN}" ]]; then
  log "applying retention policy"
  restic \
    --password-file "${RESTIC_PASSWORD_FILE}" \
    -r "sftp:${ANUBIS_USER}@${ANUBIS_HOST}:${ANUBIS_PATH}" \
    forget --prune \
      --keep-daily "${KEEP_DAILY}" \
      --keep-weekly "${KEEP_WEEKLY}" \
      --keep-monthly "${KEEP_MONTHLY}"
fi

log "done"
