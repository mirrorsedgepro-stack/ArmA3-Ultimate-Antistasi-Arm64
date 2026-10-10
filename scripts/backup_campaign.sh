#!/usr/bin/env bash
# ==============================================================================
# Antistasi Campaign Automated Backup Tool
# Archives persistent profile saves and rotates historical backups
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${ROOT_DIR}/backups"
PROFILES_DIR="${ROOT_DIR}/configs/profiles"
RETENTION_COUNT=14

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/antistasi_campaign_${TIMESTAMP}.tar.gz"

echo "=== Starting Antistasi Campaign Backup ==="
echo "Source: ${PROFILES_DIR}"
echo "Destination: ${BACKUP_FILE}"

if [ ! -d "$PROFILES_DIR" ]; then
    echo "Creating empty profile directory and aborting backup (no save yet)."
    mkdir -p "$PROFILES_DIR"
    exit 0
fi

# The server writes its profiles as root, so the archive is made by a throwaway container (read-only mount)
# rather than by this user, who can't read them. Works whether or not the server is running.
IMAGE="${BACKUP_IMAGE:-arma3-antistasi:latest}"
if ! docker run --rm --entrypoint tar -v "${ROOT_DIR}/configs:/configs:ro" "$IMAGE" \
        -czf - -C /configs profiles > "${BACKUP_FILE}.tmp"; then
    rm -f "${BACKUP_FILE}.tmp"
    echo "Error: could not archive ${PROFILES_DIR}." >&2
    exit 1
fi
mv "${BACKUP_FILE}.tmp" "$BACKUP_FILE"
if ! tar -tzf "$BACKUP_FILE" | grep -q '\.vars\.Arma3Profile$'; then
    echo "Warning: the archive holds no campaign save (*.vars.Arma3Profile) yet." >&2
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "Backup created successfully: $(basename "$BACKUP_FILE") (${BACKUP_SIZE})"

# Prune old backups, retaining the newest RETENTION_COUNT files
echo "Cleaning up older backups (retaining newest ${RETENTION_COUNT})..."
BACKUP_COUNT=$(ls -1t "${BACKUP_DIR}"/antistasi_campaign_*.tar.gz 2>/dev/null | wc -l)
if [ "$BACKUP_COUNT" -gt "$RETENTION_COUNT" ]; then
    ls -1t "${BACKUP_DIR}"/antistasi_campaign_*.tar.gz | tail -n +"$((RETENTION_COUNT + 1))" | xargs -r rm -f
    echo "Removed $((BACKUP_COUNT - RETENTION_COUNT)) older backup(s)."
else
    echo "Current total backups: ${BACKUP_COUNT} (within limit of ${RETENTION_COUNT})."
fi

echo "=== Backup Complete ==="
