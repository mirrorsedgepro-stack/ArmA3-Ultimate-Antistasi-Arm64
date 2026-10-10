#!/usr/bin/env bash
# Restart the Arma server (only) as soon as it has been empty for EMPTY_FOR seconds: for changes that need a
# restart (servermods, bridge) without kicking anyone. Backs up the campaign first, then waits for the bridge.
#   nohup ./scripts/restart_when_empty.sh > logs/restart_when_empty.log 2>&1 &
set -uo pipefail
cd "$(dirname "$0")/.."
EMPTY_FOR="${EMPTY_FOR:-180}"
players() {  # the Game Master's live count (log-based), else A2S through the telemetry bridge
    curl -sf --max-time 5 http://127.0.0.1:8765/api/training | python3 -c 'import json,sys;print(json.load(sys.stdin)["players"])' 2>/dev/null \
    || curl -sf --max-time 5 -H "x-api-key: $(grep -E '^TELEMETRY_API_KEY=' .env | cut -d= -f2-)" http://127.0.0.1:2310/api/players \
       | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("players",d if isinstance(d,list) else [])))' 2>/dev/null \
    || echo unknown
}
echo "$(date -u +%T) waiting for the server to be empty for ${EMPTY_FOR}s"
empty_since=""
while true; do
    n="$(players)"
    if [ "$n" = "0" ]; then
        empty_since="${empty_since:-$(date +%s)}"
        if [ $(( $(date +%s) - empty_since )) -ge "$EMPTY_FOR" ]; then break; fi
    else
        [ -n "$empty_since" ] && echo "$(date -u +%T) players back ($n); waiting again"
        empty_since=""
    fi
    sleep 15
done
echo "$(date -u +%T) empty for ${EMPTY_FOR}s: backing up and restarting the Arma server"
./scripts/manage.sh backup || { echo "backup failed: not restarting"; exit 1; }
[ "$(players)" = "0" ] || { echo "$(date -u +%T) a player joined during the backup: not restarting"; exec "$0"; }
docker compose restart arma3
started="$(docker inspect arma3_antistasi --format '{{.State.StartedAt}}')"
for _ in $(seq 1 90); do
    if docker logs --since "$started" arma3_antistasi 2>&1 | grep -qE 'A3GM\|(ready|error)'; then break; fi
    sleep 10
done
docker logs --since "$started" arma3_antistasi 2>&1 | grep -E 'A3GM\|(installed|ready|error|radios)' | sed "s/^/$(date -u +%T) /"
echo "$(date -u +%T) done"
