#!/usr/bin/env bash
# C-Gate healthcheck:
#  - hard-fail immediately if the command port doesn't answer (server dead)
#  - fail on networks stuck in a bad state (e.g. hung in 'closed' after a
#    power loss), but only after the bad state persists for GRACE consecutive
#    probes, and after first trying in-place recovery (net open + net sync)
#    over the command port. This keeps the self-healing restart for genuine
#    hangs without restart-looping when a restart cannot help (e.g. a unit
#    feeding garbage that keeps a network in State=error).
set -u

HOST="127.0.0.1"
PORT="20023"
allowed_re='State=(new|sync|ok)'
STATE_FILE="/tmp/cgate-health.bad-count"
GRACE=10 # consecutive bad probes (30s interval => 5 min) before unhealthy

# Docker only shows healthcheck output in `docker inspect`; mirror everything
# to PID 1's stdout so it lands in the add-on log where it can be seen.
log() {
    local msg="[healthcheck] $*"
    echo "$msg" >&2
    echo "$msg" >/proc/1/fd/1 2>/dev/null || true
}

cgate() {
    {
        printf '%s\r\n' "$1"
        sleep 1
    } | nc -w 5 "$HOST" "$PORT" 2>/dev/null || true
}

output="$(cgate 'net list')"

if ! grep -Eiq '^201[[:space:]]+Service ready' <<<"$output"; then
    log "FAIL: no C-Gate banner on ${HOST}:${PORT}"
    exit 1
fi

net_lines="$(grep -Ei '^131[- ]?network=' <<<"$output" || true)"
if [[ -z "$net_lines" ]]; then
    bad="(no 'net list' output)"
else
    bad="$(grep -Eiv "$allowed_re" <<<"$net_lines" || true)"
fi

if [[ -z "$bad" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
        log "recovered: all networks back in new/sync/ok after $(cat "$STATE_FILE" 2>/dev/null || echo '?') bad probe(s)"
        rm -f "$STATE_FILE"
    fi
    exit 0
fi

count=$(($(cat "$STATE_FILE" 2>/dev/null || echo 0) + 1))
echo "$count" >"$STATE_FILE"
while IFS= read -r line; do
    log "bad network state (probe ${count}/${GRACE}): ${line}"
done <<<"$bad"

# Try in-place recovery before resorting to a container restart.
while IFS= read -r line; do
    net="$(grep -Eo 'network=[0-9]+' <<<"$line" | cut -d= -f2 || true)"
    if [[ -n "$net" ]]; then
        open_resp="$(cgate "net open ${net}" | grep -Ev '^201 ' | tr -d '\r' | tr '\n' ' ')"
        sync_resp="$(cgate "net sync ${net}" | grep -Ev '^201 ' | tr -d '\r' | tr '\n' ' ')"
        log "recovery attempt for net ${net}: open -> ${open_resp:-no response}; sync -> ${sync_resp:-no response}"
    fi
done <<<"$bad"

if ((count >= GRACE)); then
    log "FAIL: bad network state persisted for ${GRACE} consecutive probes, going unhealthy (watchdog may restart add-on)"
    exit 1
fi

exit 0
