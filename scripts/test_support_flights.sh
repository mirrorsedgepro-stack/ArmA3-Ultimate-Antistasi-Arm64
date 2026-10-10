#!/usr/bin/env bash
# Restart Arma once it's empty (restart_when_empty.sh), then fly the support assets against stand-in casualties
# ("@<grid>") and report each stage, boarding counts and unloads: a regression test for the helicopter scripts.
set -uo pipefail
cd "$(dirname "$0")/.."
./scripts/restart_when_empty.sh || exit 1
GM=/home/jcee-slave/openclaw-gm
start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for c in 'TRANSPORT|ft1|@11781837|12781967' 'MEDEVAC|fm1|@12281573|extract' 'BACKUP|fb1|@12281573|air'; do
    (cd "$GM" && PYTHONPATH=. timeout 60 ./venv/bin/python main.py --arma-cmd "$c" 2>&1 | grep -oE '\-> (ok|fail): .*$' | tail -1 | sed "s/^/$(date -u +%T) ${c%%|*}: /")
done
for _ in $(seq 1 60); do  # up to 15 minutes for all three to finish
    n=$(docker logs --since "$start" arma3_antistasi 2>&1 | grep -cE 'A3GM\|(transport\|ft1\|(arrived|failed)|medevac\|fm1\|(done|failed)|backup\|fb1\|(arrived|lost|stuck))')
    [ "$n" -ge 3 ] && break
    sleep 15
done
echo "=== stages"
docker logs --since "$start" arma3_antistasi 2>&1 | grep -E 'A3GM\|(transport\|ft1|medevac\|fm1|backup\|fb1)\|' | cut -c1-160
echo "=== script errors"
docker logs --since "$start" arma3_antistasi 2>&1 | grep -A6 'Error in expression' | grep -E 'fn_init' | head -5
echo "$(date -u +%T) done"
