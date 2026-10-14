#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Wait for docker daemon to be responsive (timeout 120s)
COUNT=0
while ! docker info >/dev/null 2>&1; do
    sleep 2
    COUNT=$((COUNT + 2))
    if [ "$COUNT" -ge 120 ]; then
        echo "Docker not available after 120s"
        exit 1
    fi
done

# Ensure binfmt emulation is registered
"${SCRIPT_DIR}/setup_binfmt.sh"

# If teamspeak_server container exists and is not running, restart it
if docker ps -a --format '{{.Names}}' | grep -q '^teamspeak_server$'; then
    STATUS=$(docker inspect --format '{{.State.Status}}' teamspeak_server 2>/dev/null || echo "unknown")
    if [ "$STATUS" != "running" ]; then
        echo "teamspeak_server is in state '${STATUS}', restarting..."
        docker restart teamspeak_server || true
    fi
fi

# The audio bots retry a lost TeamSpeak connection only every 5 min and sat disconnected for hours on
# 2026-10-13/14: if TeamSpeak is up but a bot is not connected (Status 2), restart the bot container.
if [ "$(docker inspect --format '{{.State.Status}}' teamspeak_server 2>/dev/null)" = "running" ] \
   && docker ps --format '{{.Names}}' | grep -q '^ts3audiobot$'; then
    BOTS=$(curl -sf --max-time 5 http://127.0.0.1:58913/api/bot/list || echo '[]')
    if ! python3 -c 'import json,sys; b=json.loads(sys.argv[1]); sys.exit(0 if b and all(x.get("Status")==2 for x in b) else 1)' "$BOTS"; then
        echo "audio bots not connected ($BOTS), restarting ts3audiobot..."
        docker restart ts3audiobot || true
    fi
fi
