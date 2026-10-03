#!/usr/bin/env bash
# ==============================================================================
# Antistasi Campaign Restore Tool
# Restores profile saves from an existing backup archive safely
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${ROOT_DIR}/backups"
PROFILES_DIR="${ROOT_DIR}/configs/profiles"

if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    echo "Error: No backup files found in ${BACKUP_DIR}."
    exit 1
fi

echo "=== Antistasi Campaign Restoration ==="

TARGET_ARCHIVE="${1:-}"

if [ -z "$TARGET_ARCHIVE" ]; then
    echo "Available backups (newest first):"
    echo "--------------------------------------------------------"
    select ARCHIVE_CHOICE in $(ls -1t "${BACKUP_DIR}"/antistasi_campaign_*.tar.gz); do
        if [ -n "$ARCHIVE_CHOICE" ]; then
            TARGET_ARCHIVE="$ARCHIVE_CHOICE"
            break
        else
            echo "Invalid selection. Please enter a valid number."
        fi
    done
fi

if [ ! -f "$TARGET_ARCHIVE" ]; then
    echo "Error: File '$TARGET_ARCHIVE' not found."
    exit 1
fi

echo "Selected archive: $(basename "$TARGET_ARCHIVE")"

# Check if Arma 3 container is running
IS_RUNNING=$(docker ps -q --filter "name=arma3_antistasi" 2>/dev/null || true)
if [ -n "$IS_RUNNING" ]; then
    echo "Warning: Container 'arma3_antistasi' is currently running."
    read -r -p "Stop the container before restoring to prevent file corruption? [Y/n] " CONFIRM_STOP
    CONFIRM_STOP=${CONFIRM_STOP:-Y}
    if [[ "$CONFIRM_STOP" =~ ^[Yy]$ ]]; then
        echo "Stopping container..."
        docker compose -f "${ROOT_DIR}/docker-compose.yml" stop
    else
        echo "Restoring while container is running is risky. Proceeding at your own risk..."
    fi
fi

# Safety snapshot of current state before overwriting
if [ -d "$PROFILES_DIR" ] && [ -n "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]; then
    SAFETY_FILE="${BACKUP_DIR}/pre_restore_safety_$(date +"%Y%m%d_%H%M%S").tar.gz"
    echo "Creating safety backup of current profiles to $(basename "$SAFETY_FILE")..."
    tar -czf "$SAFETY_FILE" -C "${ROOT_DIR}/configs" profiles
fi

echo "Restoring profiles from $(basename "$TARGET_ARCHIVE")..."
tar -xzf "$TARGET_ARCHIVE" -C "${ROOT_DIR}/configs"

echo "Restoration completed successfully."
if [ -n "$IS_RUNNING" ]; then
    read -r -p "Restart the Arma 3 container now? [Y/n] " CONFIRM_START
    CONFIRM_START=${CONFIRM_START:-Y}
    if [[ "$CONFIRM_START" =~ ^[Yy]$ ]]; then
        docker compose -f "${ROOT_DIR}/docker-compose.yml" start
        echo "Server container restarted."
    fi
fi
