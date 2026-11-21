#!/usr/bin/env bash
# C-Gate healthcheck (1.0.9).
#
# Docker runs this every 30 s with --timeout=10s --retries=1, so THIS script decides when the
# add-on is unhealthy (and the Supervisor watchdog restarts it): only after GRACE consecutive bad
# probes (~5 min). Until 1.0.8 every C-Gate call took ~6 s (sleep 1 | nc -w 5, no quit), so
# Docker's 15 s timeout killed the probe before any recovery ran, and --retries=3 restarted
# C-Gate after ~2 min (2026-11-18 03:13 and 03:36).
#
# One probe = one short session: `net list` + `quit` (C-Gate then closes the socket), ~1 s.
#  - healthy: every network's interface is running, whatever its State (new/sync/ok/error: a
#    State=error with a running interface clears on C-Gate's next good command).
#  - bad: an interface closed/closing/streamsclosed (a closed net doesn't auto-reopen after a
#    clean close; 2026-09-13 the 1st floor stayed dead), no `net list` reply, or no banner.
#  - recovery: for closed interfaces, `net open <n>` in ONE detached background job, 254 (the CNI)
#    first because 251/252 are bridged through it; a bridged reopen takes ~18 s. Never
#    `net sync`: C-Gate syncs on open, and a manual sync during startup fails with 408.
#  - nothing during C-Gate's first STARTUP_GRACE_S seconds (its own startup sync).
#  - the add-on log gets a line only when the summary changes, not every 30 s.
set -u

HOST="${CGATE_HOST:-127.0.0.1}"
PORT="${CGATE_PORT:-20023}"
STATE_DIR="${HC_STATE_DIR:-/tmp}"
BAD_FILE="${STATE_DIR}/cgate-health.bad-count"
LAST_FILE="${STATE_DIR}/cgate-health.last"
LOCK_FILE="${STATE_DIR}/cgate-health.recovery.pid"
GRACE="${HC_GRACE:-10}"                      # consecutive bad probes (30 s apart => 5 min)
STARTUP_GRACE_S="${HC_STARTUP_GRACE_S:-180}" # C-Gate's own startup sync takes 2-7 min
BANNER_TIMEOUT_S="${HC_BANNER_TIMEOUT_S:-6}" # first line (a C-Gate without DNS needs ~5 s)
READ_TIMEOUT_S="${HC_READ_TIMEOUT_S:-2}"     # silence per later line; worst case 8 s < 10 s
OPEN_TIMEOUT_S="${HC_OPEN_TIMEOUT_S:-60}"    # silence allowed while a `net open` runs
CNI_NET="${HC_CNI_NET:-254}"

# Docker shows healthcheck output only in `docker inspect`; mirror it to PID 1's stdout so it
# lands in the add-on log.
log() {
    local msg="[healthcheck] $*"
    echo "$msg" >&2
    if [[ -z "${HC_NO_PID1_LOG:-}" ]]; then
        echo "$msg" >/proc/1/fd/1 2>/dev/null || true
    fi
}

# One C-Gate session: send the commands plus `quit`, print the reply lines (CR stripped) until
# `204` (closing), EOF, or silence (BANNER_TIMEOUT_S for the first line, READ_TIMEOUT_S after).
# Returns 1 if the connect fails.
cgate_session() {
    local line c t="$BANNER_TIMEOUT_S"
    exec 3<>"/dev/tcp/${HOST}/${PORT}" || return 1
    {
        for c in "$@"; do printf '%s\r\n' "$c"; done
        printf 'quit\r\n'
    } >&3 2>/dev/null || true
    while IFS= read -r -t "$t" line <&3; do
        t="$READ_TIMEOUT_S"
        line="${line%$'\r'}"
        printf '%s\n' "$line"
        [[ "$line" == 204* ]] && break
    done
    exec 3<&- 3>&-
    return 0
}

# Seconds since PID 1 (java, `exec`ed by run.sh) started; empty if unknown.
cgate_age_s() {
    if [[ -n "${HC_AGE_S:-}" ]]; then
        echo "$HC_AGE_S"
        return
    fi
    local up stat rest start
    up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" || return 0
    stat="$(cat /proc/1/stat 2>/dev/null)" || return 0
    rest="${stat##*) }"                     # fields 3.. (the comm field may hold spaces)
    start="$(awk '{print $20}' <<<"$rest")" # field 22: starttime in clock ticks (USER_HZ 100)
    [[ -n "$up" && -n "$start" ]] || return 0
    awk -v u="$up" -v s="$start" 'BEGIN { printf "%d\n", u - s / 100 }'
}

# Background job: `net open` each network in the given order, logging C-Gate's replies.
recover() {
    local net resp
    echo $$ >"$LOCK_FILE"
    for net in "$@"; do
        resp="$(BANNER_TIMEOUT_S="$OPEN_TIMEOUT_S" READ_TIMEOUT_S="$OPEN_TIMEOUT_S" cgate_session "net open ${net}" 2>/dev/null \
            | grep -Ev '^(201|204) ' | tr '\n' ' ')"
        log "recovery: net open ${net} -> ${resp:-no response}"
    done
    rm -f "$LOCK_FILE"
}

if [[ "${1:-}" == "--recover" ]]; then
    shift
    recover "$@"
    exit 0
fi

recovery_running() {
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null)" || return 1
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Log `summary` only when it differs from the previous probe's.
report() {
    if [[ "$(cat "$LAST_FILE" 2>/dev/null)" != "$1" ]]; then
        log "$1"
        printf '%s' "$1" >"$LAST_FILE"
    fi
}

age="$(cgate_age_s)"
if [[ -n "$age" ]] && ((age < STARTUP_GRACE_S)); then
    rm -f "$BAD_FILE"
    report "startup: C-Gate up for less than ${STARTUP_GRACE_S}s, not checked yet"
    exit 0
fi

output="$(cgate_session 'net list' 2>/dev/null)"
nets="$(grep -E '^131[- ]network=' <<<"$output" | sed -E 's/^131[- ]//')"
bad=""
closed=()
if ! grep -q '^201 ' <<<"$output"; then
    bad="no C-Gate banner on ${HOST}:${PORT}"
elif [[ -z "$nets" ]]; then
    bad="no 'net list' reply: $(tr '\n' ' ' <<<"$output" | cut -c1-200)"
else
    while IFS= read -r line; do
        if [[ "$line" =~ InterfaceState=(closed|closing|streamsclosed) ]]; then
            n="$(grep -Eo 'network=[0-9]+' <<<"$line" | cut -d= -f2)"
            [[ -n "$n" ]] && closed+=("$n")
        fi
    done <<<"$nets"
    if ((${#closed[@]} > 0)); then
        bad="interface not running: $(grep -E 'InterfaceState=(closed|closing|streamsclosed)' <<<"$nets" | tr '\n' ';')"
    fi
fi

if [[ -z "$bad" ]]; then
    if [[ -f "$BAD_FILE" ]]; then
        log "recovered after $(cat "$BAD_FILE" 2>/dev/null || echo '?') bad probe(s)"
        rm -f "$BAD_FILE"
    fi
    report "ok: $(tr '\n' ';' <<<"$nets")"
    exit 0
fi

count=$(($(cat "$BAD_FILE" 2>/dev/null || echo 0) + 1))
echo "$count" >"$BAD_FILE"
log "bad (probe ${count}/${GRACE}): ${bad}"
printf '%s' "bad" >"$LAST_FILE"

if ((${#closed[@]} > 0)); then
    if recovery_running; then
        log "recovery still running (pid $(cat "$LOCK_FILE" 2>/dev/null)), not started again"
    else
        order=()
        for n in "${closed[@]}"; do [[ "$n" == "$CNI_NET" ]] && order+=("$n"); done
        for n in "${closed[@]}"; do [[ "$n" != "$CNI_NET" ]] && order+=("$n"); done
        log "recovery: net open ${order[*]} (background)"
        if command -v setsid >/dev/null 2>&1; then
            setsid bash "$0" --recover "${order[@]}" </dev/null >/dev/null 2>&1 &
        else
            nohup bash "$0" --recover "${order[@]}" </dev/null >/dev/null 2>&1 &
        fi
    fi
fi

if ((count >= GRACE)); then
    log "FAIL: bad for ${GRACE} consecutive probes, going unhealthy (the watchdog restarts the add-on)"
    exit 1
fi
exit 0
