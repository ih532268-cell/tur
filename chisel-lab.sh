#!/usr/bin/env bash
# chisel-lab.sh - local tunnel/pivot lab for chisel.
# Everything stays on THIS device: every listener binds to 127.x.x.x only. Nothing touches your network.
# Usage: bash chisel-lab.sh        (override binary: CHISEL=/path/to/chisel bash chisel-lab.sh)

CHISEL="${CHISEL:-chisel}"
LOG="$HOME/chisel-lab-logs"; mkdir -p "$LOG"; rm -f "$LOG"/*
PIDS=(); pass=0; fail=0; skip=0

cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
sk()  { echo "  SKIP  $1"; skip=$((skip+1)); }
get() { curl -s -m 6 "$@"; }
port_open() { (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null; }
# wait_port host port pid -> 0 once the port accepts connections; 1 if the process died or timeout
wait_port() { for _ in $(seq 1 40); do port_open "$1" "$2" && return 0; kill -0 "$3" 2>/dev/null || return 1; sleep 0.25; done; return 1; }

# wait_connected logname pid -> 0 once the client reports "Connected" (the local port opens BEFORE that)
wait_connected() { for _ in $(seq 1 60); do grep -q "client: Connected" "$LOG/$1.log" && return 0; kill -0 "$2" 2>/dev/null || return 1; sleep 0.25; done; return 1; }

# start_srv name host port cmd...  -> returns 0 only if the port is really open (retries if it dies at launch)
start_srv() {
  local name=$1 host=$2 port=$3; shift 3
  for _ in 1 2 3 4 5 6; do
    "$@" >"$LOG/$name.log" 2>&1 & LAST=$!
    if wait_port "$host" "$port" "$LAST"; then PIDS+=("$LAST"); return 0; fi
    kill "$LAST" 2>/dev/null; wait "$LAST" 2>/dev/null
  done
  return 1
}
# start_cli name cmd...  -> returns 0 if the process is still alive after a second
start_cli() {
  local name=$1; shift
  for _ in 1 2 3 4 5 6; do
    "$@" >"$LOG/$name.log" 2>&1 & LAST=$!
    sleep 1
    if kill -0 "$LAST" 2>/dev/null; then PIDS+=("$LAST"); return 0; fi
    wait "$LAST" 2>/dev/null
  done
  return 1
}
stop() { for p in "$@"; do kill "$p" 2>/dev/null; done; wait "$@" 2>/dev/null; }
show() { echo "        --- last log lines ($1):"; tail -n 4 "$LOG/$1.log" 2>/dev/null | sed 's/^/        /'; }
# a client counts as "rejected" only if it tried to connect, never got "Connected", and the server was up
rejected() { grep -q "client: Connecting" "$LOG/$1.log" && ! grep -q "client: Connected" "$LOG/$1.log" && grep -q -E "Authentication failed|handshake failed|fingerprint|Connection error" "$LOG/$1.log"; }

command -v "$CHISEL" >/dev/null 2>&1 || { echo "chisel not found. Install it first."; exit 1; }
ver=""; for _ in 1 2 3 4 5; do ver=$("$CHISEL" --version 2>/dev/null) && [ -n "$ver" ] && break; done
echo "chisel: ${ver:-?}   logs: $LOG"

# ---- "internal service": a chisel server answering /health with OK, on a loopback alias ----
INT=127.0.0.2
if ! start_srv internal "$INT" 9000 "$CHISEL" server --host "$INT" --port 9000; then
  INT=127.0.0.1
  start_srv internal "$INT" 9000 "$CHISEL" server --host "$INT" --port 9000 || { echo "cannot start internal service"; exit 1; }
  echo "note: 127.0.0.2 not available here, using 127.0.0.1 (tests still exercise the tunnel)"
fi
[ "$(get "http://$INT:9000/health")" = "OK" ] && echo "internal service $INT:9000 is up" || { echo "internal service broken"; exit 1; }

t1() { echo; echo "T1 reverse port forward: internal side exposes a service to the operator side"
  start_srv t1srv 127.0.0.1 9101 "$CHISEL" server --host 127.0.0.1 --port 9101 --reverse || { bad "server did not start"; return; }; local S=$LAST
  start_cli t1cli "$CHISEL" client 127.0.0.1:9101 "R:127.0.0.1:9201:$INT:9000" || { bad "client did not start"; stop "$S"; return; }; local C=$LAST
  wait_connected t1cli "$C"; wait_port 127.0.0.1 9201 "$C" >/dev/null
  [ "$(get http://127.0.0.1:9201/health)" = "OK" ] && ok "operator reached internal /health via reverse tunnel (port 9201)" || { bad "reverse forward"; show t1srv; show t1cli; }
  stop "$C" "$S"; }

t2() { echo; echo "T2 forward SOCKS5 pivot: client gets a SOCKS5 proxy that exits from the server side"
  start_srv t2srv 127.0.0.1 9102 "$CHISEL" server --host 127.0.0.1 --port 9102 --socks5 || { bad "server did not start"; return; }; local S=$LAST
  start_cli t2cli "$CHISEL" client 127.0.0.1:9102 127.0.0.1:9202:socks || { bad "client did not start"; stop "$S"; return; }; local C=$LAST
  wait_connected t2cli "$C"
  [ "$(get --socks5-hostname 127.0.0.1:9202 "http://$INT:9000/health")" = "OK" ] && ok "reached internal service through SOCKS5 (port 9202)" || { bad "forward socks"; show t2srv; show t2cli; }
  stop "$C" "$S"; }

t3() { echo; echo "T3 reverse SOCKS5: operator side gets a SOCKS5 proxy that exits from the client side"
  start_srv t3srv 127.0.0.1 9103 "$CHISEL" server --host 127.0.0.1 --port 9103 --reverse || { bad "server did not start"; return; }; local S=$LAST
  start_cli t3cli "$CHISEL" client 127.0.0.1:9103 R:127.0.0.1:9203:socks || { bad "client did not start"; stop "$S"; return; }; local C=$LAST
  wait_connected t3cli "$C"; wait_port 127.0.0.1 9203 "$C" >/dev/null
  [ "$(get --socks5-hostname 127.0.0.1:9203 "http://$INT:9000/health")" = "OK" ] && ok "reached internal service through reverse SOCKS5 (port 9203)" || { bad "reverse socks"; show t3srv; show t3cli; }
  stop "$C" "$S"; }

t4() { echo; echo "T4 authentication and fingerprint pinning"
  start_srv t4srv 127.0.0.1 9104 "$CHISEL" server --host 127.0.0.1 --port 9104 --auth lab:secret || { bad "server did not start"; return; }; local S=$LAST
  local FP; FP=$(grep -o 'Fingerprint [^ ]*' "$LOG/t4srv.log" | awk '{print $2}')
  [ -n "$FP" ] || { bad "could not read server fingerprint"; stop "$S"; return; }
  start_cli t4a "$CHISEL" client --auth lab:WRONG 127.0.0.1:9104 "127.0.0.1:9204:$INT:9000"; local A=$LAST; sleep 2
  if port_open 127.0.0.1 9104 && [ -z "$(get http://127.0.0.1:9204/health)" ] && rejected t4a; then ok "wrong password rejected by a running server"; else bad "wrong password not cleanly rejected"; show t4a; fi
  stop "$A"
  start_cli t4b "$CHISEL" client --auth lab:secret --fingerprint "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" 127.0.0.1:9104 "127.0.0.1:9205:$INT:9000"; local B=$LAST; sleep 2
  if port_open 127.0.0.1 9104 && [ -z "$(get http://127.0.0.1:9205/health)" ] && rejected t4b; then ok "wrong server fingerprint rejected (MITM protection)"; else bad "wrong fingerprint not cleanly rejected"; show t4b; fi
  stop "$B"
  kill -0 "$S" 2>/dev/null || { bad "T4 server process CRASHED during the test (not an auth problem)"; show t4srv; return; }
  start_cli t4c "$CHISEL" client --auth lab:secret --fingerprint "$FP" 127.0.0.1:9104 "127.0.0.1:9206:$INT:9000" || { bad "client did not start"; stop "$S"; return; }; local D=$LAST
  wait_connected t4c "$D"
  [ "$(get http://127.0.0.1:9206/health)" = "OK" ] && ok "correct password + fingerprint accepted" || { bad "correct credentials failed"; show t4c; }
  stop "$D" "$S"; }

t5() { echo; echo "T5 reconnect after the server dies (a Termux problem reported upstream in 2020)"
  start_srv t5srv 127.0.0.1 9105 "$CHISEL" server --host 127.0.0.1 --port 9105 || { bad "server did not start"; return; }; local S=$LAST
  start_cli t5cli "$CHISEL" client --max-retry-interval 3s 127.0.0.1:9105 "127.0.0.1:9207:$INT:9000" || { bad "client did not start"; stop "$S"; return; }; local C=$LAST
  wait_connected t5cli "$C"
  [ "$(get http://127.0.0.1:9207/health)" = "OK" ] || { bad "baseline tunnel failed"; stop "$C" "$S"; return; }
  stop "$S"; sleep 3
  kill -0 "$C" 2>/dev/null && ok "client process survived server death" || { bad "client exited when the server died"; return; }
  start_srv t5srv2 127.0.0.1 9105 "$CHISEL" server --host 127.0.0.1 --port 9105 || { bad "server could not be restarted"; stop "$C"; return; }
  local back=no; for _ in $(seq 1 25); do [ "$(get http://127.0.0.1:9207/health)" = "OK" ] && { back=yes; break; }; sleep 1; done
  [ $back = yes ] && ok "tunnel came back by itself after the server restarted" || { bad "no automatic reconnect"; show t5cli; }
  stop "$C"; }

t6() { echo; echo "T6 throughput (30 MB through the tunnel vs directly)"
  command -v python3 >/dev/null 2>&1 || { sk "python3 not installed (pkg install python)"; return; }
  head -c 31457280 /dev/zero > "$LOG/blob"
  python3 -m http.server 9006 --bind "$INT" -d "$LOG" >"$LOG/http.log" 2>&1 & local H=$!; PIDS+=("$H")
  wait_port "$INT" 9006 "$H" >/dev/null
  start_srv t6srv 127.0.0.1 9106 "$CHISEL" server --host 127.0.0.1 --port 9106 || { bad "server did not start"; return; }; local S=$LAST
  start_cli t6cli "$CHISEL" client 127.0.0.1:9106 "127.0.0.1:9208:$INT:9006" || { bad "client did not start"; stop "$S"; return; }; local C=$LAST
  wait_connected t6cli "$C"
  local d t
  d=$(curl -s -o /dev/null -m 60 -w '%{speed_download}' "http://$INT:9006/blob")
  t=$(curl -s -o /dev/null -m 60 -w '%{speed_download}' "http://127.0.0.1:9208/blob")
  echo "        direct: $(awk -v v="$d" 'BEGIN{printf "%.1f", v/1048576}') MB/s    tunnel: $(awk -v v="$t" 'BEGIN{printf "%.1f", v/1048576}') MB/s"
  [ "${t%.*}" -gt 0 ] 2>/dev/null && ok "transfer through tunnel completed" || bad "tunnel transfer failed"
  stop "$C" "$S"; }

t1; t2; t3; t4; t5; t6
echo; echo "RESULT: $pass passed, $fail failed, $skip skipped   (logs: $LOG)"
[ $fail -eq 0 ]
