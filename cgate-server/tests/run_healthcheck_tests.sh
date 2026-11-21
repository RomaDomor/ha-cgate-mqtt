#!/usr/bin/env bash
# Runs healthcheck.sh against tests/fake_cgate.py inside Alpine 3.19 (the add-on's base).
#   docker run --rm -v "$PWD":/w -w /w alpine:3.19 sh -c 'apk add -q bash python3 && bash tests/run_healthcheck_tests.sh'
set -u
cd "$(dirname "$0")/.."
HC="$PWD/healthcheck.sh"
T="$(mktemp -d)"
export HC_STATE_DIR="$T/hc" HC_NO_PID1_LOG=1 HC_AGE_S=1000 HC_GRACE=3 CGATE_PORT=20023
mkdir -p "$HC_STATE_DIR"
STATE="$T/state.json"
fails=0
ok()   { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fails=$((fails + 1)); }
set_state() { printf '%s' "$1" >"$STATE"; : >"$STATE.cmds"; }
reset_hc() { rm -rf "$HC_STATE_DIR"; mkdir -p "$HC_STATE_DIR"; }
OK='"254":"State=ok InterfaceState=running","251":"State=ok InterfaceState=running","252":"State=ok InterfaceState=running"'

set_state "{\"nets\":{$OK}}"
python3 tests/fake_cgate.py "$STATE" & FAKE=$!
sleep 1

# 1. all ok: exit 0, logs once, then quiet; probe is fast; only `net list` + quit sent
reset_hc
start=$(date +%s); out=$(bash "$HC" 2>&1); rc=$?; dur=$(( $(date +%s) - start ))
[[ $rc == 0 && "$out" == *"ok: network=254"* ]] && ok "all ok" || bad "all ok: rc=$rc out=$out"
(( dur <= 2 )) && ok "probe ${dur}s" || bad "probe took ${dur}s"
[[ "$(cat "$STATE.cmds")" == $'net list\nquit' ]] && ok "only net list + quit" || bad "cmds: $(cat "$STATE.cmds")"
out=$(bash "$HC" 2>&1); [[ -z "$out" ]] && ok "no repeat log" || bad "repeat log: $out"

# 2. State=error with a running interface: healthy, no recovery
reset_hc
set_state '{"nets":{"254":"State=error InterfaceState=running","251":"State=ok InterfaceState=running","252":"State=ok InterfaceState=running"}}'
out=$(bash "$HC" 2>&1); rc=$?
[[ $rc == 0 && ! -f "$HC_STATE_DIR/cgate-health.bad-count" ]] && ok "State=error ignored" || bad "State=error: rc=$rc $out"
grep -q "net open" "$STATE.cmds" && bad "recovery on State=error" || ok "no net open for State=error"

# 3. 251 closed: bad 1/3, background net open 251, no net sync, then recovered
reset_hc
set_state '{"nets":{"254":"State=ok InterfaceState=running","251":"State=new InterfaceState=closed","252":"State=ok InterfaceState=running"}}'
out=$(bash "$HC" 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"bad (probe 1/3)"* && "$out" == *"net open 251 (background)"* ]] && ok "251 closed -> recovery" || bad "251 closed: rc=$rc $out"
sleep 2
grep -q "^net open 251$" "$STATE.cmds" && ok "net open 251 sent" || bad "no net open 251: $(cat "$STATE.cmds")"
grep -q "net sync" "$STATE.cmds" && bad "net sync sent" || ok "never net sync"
out=$(bash "$HC" 2>&1)
[[ "$out" == *"recovered after 1 bad probe"* ]] && ok "recovered" || bad "not recovered: $out"

# 4. all closed: one job, 254 first
reset_hc
set_state '{"nets":{"254":"State=new InterfaceState=closed","251":"State=new InterfaceState=closed","252":"State=new InterfaceState=streamsclosed"}}'
bash "$HC" >/dev/null 2>&1; sleep 2
order=$(grep "^net open" "$STATE.cmds" | tr '\n' ',')
[[ "$order" == "net open 254,net open 252,net open 251," || "$order" == "net open 254,net open 251,net open 252," ]] && ok "CNI first: $order" || bad "order: $order"

# 5. slow reopen: second probe sees the running recovery and does not start another
reset_hc
set_state '{"open_delay_s":6,"nets":{"254":"State=ok InterfaceState=running","251":"State=new InterfaceState=closed","252":"State=ok InterfaceState=running"}}'
bash "$HC" >/dev/null 2>&1; sleep 1
out=$(bash "$HC" 2>&1)
[[ "$out" == *"recovery still running"* ]] && ok "no stacked recovery" || bad "stacked: $out"
[[ $(grep -c "^net open" "$STATE.cmds") == 1 ]] && ok "one net open" || bad "net opens: $(grep -c '^net open' "$STATE.cmds")"
sleep 7

# 6. startup window: no connection at all
reset_hc; set_state "{\"nets\":{$OK}}"
out=$(HC_AGE_S=30 bash "$HC" 2>&1); rc=$?
[[ $rc == 0 && ! -s "$STATE.cmds" && "$out" == *"startup"* ]] && ok "startup window" || bad "startup: rc=$rc $out cmds=$(cat "$STATE.cmds")"

# 7. C-Gate gone: unhealthy only after GRACE probes, each probe fast
reset_hc
kill $FAKE; wait $FAKE 2>/dev/null
for i in 1 2; do bash "$HC" >/dev/null 2>&1; rc=$?; [[ $rc == 0 ]] || bad "probe $i failed early (rc=$rc)"; done
start=$(date +%s); out=$(bash "$HC" 2>&1); rc=$?; dur=$(( $(date +%s) - start ))
[[ $rc == 1 && "$out" == *"FAIL: bad for 3 consecutive"* ]] && ok "unhealthy after GRACE" || bad "grace: rc=$rc $out"
(( dur <= 2 )) && ok "dead-port probe ${dur}s" || bad "dead-port probe ${dur}s"

# 8. C-Gate accepts but never answers: probe still bounded by READ_TIMEOUT_S
reset_hc; set_state '{"silent":true,"nets":{}}'
python3 tests/fake_cgate.py "$STATE" & FAKE=$!; sleep 1
start=$(date +%s); out=$(bash "$HC" 2>&1); rc=$?; dur=$(( $(date +%s) - start ))
[[ $rc == 0 && "$out" == *"no C-Gate banner"* ]] && ok "silent C-Gate counted bad" || bad "silent: rc=$rc $out"
(( dur <= 8 )) && ok "silent probe ${dur}s (< 10 s Docker timeout)" || bad "silent probe ${dur}s"
kill $FAKE

echo "failures: $fails"
exit $(( fails > 0 ))
