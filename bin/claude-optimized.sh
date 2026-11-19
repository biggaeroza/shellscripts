#!/bin/sh
#
# claude-optimized.sh - run Claude Code through the Headroom compression proxy
#
# Usage:
#   claude-optimized.sh [--port N] [--check] [--yes] [--help] [--] [CLAUDE ARGS...]
#
# Starts a Headroom proxy (headroom proxy) on 127.0.0.1, waits until it
# reports healthy, then runs Claude Code (claude) with ANTHROPIC_BASE_URL
# pointing at it, so the API traffic is compressed before it is sent. The
# proxy is stopped again when Claude Code exits. Command output is condensed
# separately by RTK through Claude Code's own hook, if you have set that up.
#
#   --port N   the proxy's port (default 8787, or $HEADROOM_PORT)
#   --check    only report: are headroom and claude installed, is the port free
#   --yes      if a stale Headroom proxy holds the port, stop it without asking
#
# Every other argument goes to claude, e.g.
#   claude-optimized.sh --resume
#   claude-optimized.sh -- --help        (claude's own help)
#
# If the port is held by a Headroom proxy left over from an earlier run, it
# is stopped (after asking); anything else on the port is left alone and the
# script stops. Needs: headroom (pip install headroom-ai), claude, and curl or
# wget for the health check.

set -eu

# shellcheck disable=SC1007 # CDPATH= (empty) for this one command, as in _template.sh
SS_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/common.sh
. "$SS_ROOT/lib/common.sh"

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; }

ASSUME_YES=0 # read by confirm() in lib/common.sh
CHECK=0
PORT=${HEADROOM_PORT:-8787}
# our options come first; the first argument we don't know, and everything
# after it (or after --), is Claude Code's
while [ $# -gt 0 ]; do
    case "$1" in
        --port) [ $# -ge 2 ] || die "--port needs a number"; PORT=$2; shift ;;
        --port=*) PORT=${1#--port=} ;;
        --check) CHECK=1 ;;
        -y|--yes) ASSUME_YES=1; export ASSUME_YES ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) break ;;
    esac
    shift
done
case "$PORT" in
    ''|*[!0-9]*) die "--port: give a port number, not '$PORT'" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port: 1 to 65535"
PROXY_URL="http://127.0.0.1:$PORT"

# port_pids prints the PIDs listening on $PORT (lsof, else fuser); nothing
# when it is free or neither tool is there.
port_pids() {
    if have_cmd lsof; then
        lsof -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true
    elif have_cmd fuser; then
        fuser "$PORT/tcp" 2>/dev/null | tr -s ' ' '\n' | grep . || true
    fi
}

# port_busy reports whether something listens on $PORT, without needing to
# know what (a connection attempt).
port_busy() {
    if have_cmd curl; then
        rc=0
        curl -s -o /dev/null --max-time 1 "$PROXY_URL/" || rc=$?
        [ "$rc" -ne 7 ] # 7: nothing listens
    else
        [ -n "$(port_pids)" ]
    fi
}

healthy() {
    if have_cmd curl; then
        curl -s --max-time 2 "$PROXY_URL/health" 2>/dev/null | grep -q healthy
    else
        wget -q -T 2 -O - "$PROXY_URL/health" 2>/dev/null | grep -q healthy
    fi
}

is_headroom() { ps -o args= -p "$1" 2>/dev/null | grep -q 'headroom.*proxy'; }

# --- check ---------------------------------------------------------------
missing=""
have_cmd headroom || missing="$missing headroom (pip install headroom-ai)"
have_cmd claude || missing="$missing claude (Claude Code)"
have_cmd curl || have_cmd wget || missing="$missing curl-or-wget"
if [ "$CHECK" -eq 1 ]; then
    if [ -z "$missing" ]; then ok "headroom, claude and curl/wget are installed"; else warn "missing:$missing"; fi
    if port_busy; then
        pids=$(port_pids | tr '\n' ' ' | sed 's/ *$//')
        warn "port $PORT is in use${pids:+ (PID $pids)}"
    else
        ok "port $PORT is free"
    fi
    exit 0
fi
[ -z "$missing" ] || die "missing:$missing"

# --- a stale proxy on the port --------------------------------------------
if port_busy; then
    pids=$(port_pids)
    [ -n "$pids" ] || die "port $PORT is in use and lsof/fuser cannot say by what: choose another with --port"
    for pid in $pids; do
        is_headroom "$pid" || die "port $PORT is used by another program (PID $pid: $(ps -o comm= -p "$pid" 2>/dev/null)): choose another with --port"
    done
    warn "a Headroom proxy from an earlier run holds port $PORT (PID $(echo "$pids" | tr '\n' ' ' | sed 's/ *$//'))"
    confirm "Stop it?" || die "port $PORT is busy"
    # shellcheck disable=SC2086 # one PID per word
    kill $pids 2>/dev/null || true
    i=0
    while port_busy && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
    if port_busy; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
    port_busy && die "port $PORT is still in use"
fi

# --- start the proxy -------------------------------------------------------
info "Starting the Headroom proxy on port $PORT..."
LOG=${TMPDIR:-/tmp}/headroom-proxy-$PORT.log
headroom proxy --port "$PORT" >"$LOG" 2>&1 &
PROXY_PID=$!

# shellcheck disable=SC2329 # called by the EXIT trap
cleanup() {
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

info "Waiting for it to load its models (5-10 s)..."
i=0
until healthy; do
    kill -0 "$PROXY_PID" 2>/dev/null || die "the proxy stopped while starting; see $LOG"
    i=$((i + 1))
    [ $i -lt 30 ] || die "the proxy did not become healthy within 30 s; see $LOG"
    sleep 1
done
ok "Headroom is compressing on $PROXY_URL"

# --- Claude Code -------------------------------------------------------------
# not exec: the trap must stop the proxy when Claude Code exits
set +e
ANTHROPIC_BASE_URL="$PROXY_URL" claude "$@"
status=$?
set -e
exit "$status"
