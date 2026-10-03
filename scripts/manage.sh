#!/usr/bin/env bash
# ==============================================================================
# Arma 3 Antistasi Dedicated Server Management CLI
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

CONTAINER_NAME="arma3_antistasi"

usage() {
    cat <<EOF
Usage: ./scripts/manage.sh [command]

Commands:
  start          Start the server in background (runs pre-flight checks)
  stop           Stop the server gracefully
  restart        Restart the server
  status         Show container status, resource usage, and active ports
  logs           Follow live server output logs
  steam-login [code] Perform one-time Steam Guard authentication (interactive or with code)
  backup         Create a compressed backup of the current Antistasi campaign
  restore        Restore an Antistasi campaign save from an existing backup
  hc             Inspect status of Headless Clients
  fps            Monitor server tickrate / FPS from game logs
  help           Display this help message
EOF
}

check_env() {
    if [ ! -f ".env" ]; then
        echo "Error: .env file does not exist!"
        echo "Please copy .env.example to .env and configure your Steam credentials:"
        echo "  cp .env.example .env"
        echo "  nano .env"
        exit 1
    fi
}


preflight() {
    check_env
    # Check binfmt on non-x86_64 hosts
    if [ "$(uname -m)" != "x86_64" ]; then
        "${SCRIPT_DIR}/setup_binfmt.sh"
    fi
}

cmd_start() {
    preflight
    echo "Starting Arma 3 Antistasi Dedicated Server..."
    docker compose up -d --build
    echo "Server launched in background."
    echo "Run './scripts/manage.sh logs' to follow initial SteamCMD downloads and startup."
}

cmd_stop() {
    echo "Stopping server container..."
    docker compose stop
    echo "Server stopped."
}

cmd_restart() {
    echo "Restarting server container..."
    docker compose restart
    echo "Server restarted."
}

cmd_status() {
    echo "=== Container Status ==="
    docker compose ps
    echo ""
    if docker ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
        echo "=== Resource Usage ==="
        docker stats --no-stream "$CONTAINER_NAME"
        echo ""
        echo "=== Active Arma 3 UDP Ports ==="
        ss -u -l -p -n | grep -E "2302|2303|2304|2305|2306" || echo "Note: Ports may take up to a minute to bind after SteamCMD finishes updates."
    else
        echo "Container is not currently running."
    fi
}

cmd_logs() {
    echo "Streaming logs from ${CONTAINER_NAME} (Ctrl+C to exit)..."
    docker compose logs -f --tail=100
}

cmd_steam_login() {
    check_env
    local guard_code="${1:-}"
    echo "=== One-Time Steam Guard Authentication ==="
    echo "Stopping server container if running..."
    docker compose stop 2>/dev/null || true
    echo ""
    if [ -n "$guard_code" ]; then
        echo "Authenticating using provided Steam Guard code: ${guard_code}..."
        docker compose run --rm -e STEAM_GUARD_CODE="$guard_code" arma3 bash -c 'exec /steamcmd/steamcmd.sh +@sSteamCmdForcePlatformType linux +login "$STEAM_USER" "$STEAM_PASSWORD" "$STEAM_GUARD_CODE" +quit'
    else
        echo "Launching interactive SteamCMD login session..."
        echo "When prompted for 'Steam Guard code:', check your email or authenticator app and enter the code."
        echo ""
        docker compose run --rm -it arma3 bash -c 'exec /steamcmd/steamcmd.sh +@sSteamCmdForcePlatformType linux +login "$STEAM_USER" "$STEAM_PASSWORD" +quit'
    fi
    echo ""
    echo "=== Authentication Session Saved ==="
    echo "You can now run './scripts/manage.sh start' to launch the server in the background."
}



cmd_backup() {
    "${SCRIPT_DIR}/backup_campaign.sh"
}

cmd_restore() {
    "${SCRIPT_DIR}/restore_campaign.sh" "$@"
}

cmd_hc() {
    echo "Checking Headless Client processes in ${CONTAINER_NAME}..."
    if docker ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
        docker exec -it "$CONTAINER_NAME" ps aux | grep -i "arma3server" || true
    else
        echo "Container is not running."
    fi
}

cmd_fps() {
    echo "Monitoring server FPS updates (Ctrl+C to exit)..."
    docker compose logs -f --tail=200 | grep --line-buffered -E "FPS|Server FPS|Antistasi" || true
}

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    start|up)
        cmd_start
        ;;
    stop|down)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs
        ;;
    steam-login|login)
        cmd_steam_login "$@"
        ;;
    backup)
        cmd_backup
        ;;
    restore)
        cmd_restore "$@"
        ;;
    hc)
        cmd_hc
        ;;
    fps)
        cmd_fps
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
