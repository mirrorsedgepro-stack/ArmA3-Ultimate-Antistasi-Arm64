#!/usr/bin/env bash
# Scheduled hard restart of the Arma server (cron, every 12 h): players get 5 minutes of in-game warnings to
# save, then the campaign is backed up and arma3 (only) is restarted. With nobody online it restarts at once.
#   NOTICE=300 ./scripts/restart_announced.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NOTICE="${NOTICE:-300}"
players() {  # the Game Master's live count (log-based), else A2S through the telemetry bridge
    curl -sf --max-time 5 http://127.0.0.1:8765/api/training | python3 -c 'import json,sys;print(json.load(sys.stdin)["players"])' 2>/dev/null \
    || curl -sf --max-time 5 -H "x-api-key: $(grep -E '^TELEMETRY_API_KEY=' .env | cut -d= -f2-)" http://127.0.0.1:2310/api/players \
       | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("players",d if isinstance(d,list) else [])))' 2>/dev/null \
    || echo unknown
}
say() {  # in-game chat through the @a3gm bridge spool (the extension ignores dotfiles until the rename)
    local id="restart$(date +%s%N)"
    printf '["%s","SAY",["%s"]]' "$id" "$1" > "gm_spool/inbox/.$id.tmp" && mv "gm_spool/inbox/.$id.tmp" "gm_spool/inbox/$id.cmd"
}
n="$(players)"
if [ "$n" != "0" ]; then
    echo "$(date -u +%T) $n player(s) online: ${NOTICE}s of warnings before the restart"
    left="$NOTICE"
    while [ "$left" -gt 0 ]; do
        if [ "$left" -ge 60 ]; then say "SCHEDULED SERVER RESTART in $((left / 60)) minute(s): save your progress now."; step=$(( left > 120 ? 60 : 30 ))
        else say "SCHEDULED SERVER RESTART in ${left} seconds."; step=$left; fi
        sleep "$step"; left=$(( left - step ))
    done
    say "SERVER RESTARTING NOW. Back in about 4 minutes."
    sleep 3
fi
echo "$(date -u +%T) backing up and restarting the Arma server"
./scripts/manage.sh backup || echo "$(date -u +%T) backup failed: restarting anyway (scheduled maintenance)"
docker compose restart arma3
started="$(docker inspect arma3_antistasi --format '{{.State.StartedAt}}')"
for _ in $(seq 1 90); do
    if docker logs --since "$started" arma3_antistasi 2>&1 | grep -qE 'A3GM\|(ready|error)'; then break; fi
    sleep 10
done
docker logs --since "$started" arma3_antistasi 2>&1 | grep -E 'A3GM\|(installed|ready|error)' | sed "s/^/$(date -u +%T) /"
echo "$(date -u +%T) done"
