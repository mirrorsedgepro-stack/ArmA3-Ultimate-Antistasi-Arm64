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

if [ ! -d "$PROFILES_DIR" ] || [ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]; then
    echo "Warning: No profile data found in ${PROFILES_DIR} yet (server might not have created a save yet)."
    # If directory exists even if empty, create a placeholder archive
    if [ -d "$PROFILES_DIR" ]; then
        tar -czf "$BACKUP_FILE" -C "${ROOT_DIR}/configs" profiles
    else
        echo "Creating empty profile directory and aborting backup."
        mkdir -p "$PROFILES_DIR"
        exit 0
    fi
else
    # Create compressed archive of profiles directory
    tar -czf "$BACKUP_FILE" -C "${ROOT_DIR}/configs" profiles
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
