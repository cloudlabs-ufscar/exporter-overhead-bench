#!/usr/bin/env bash
# exporters.sh — lifecycle management for node_exporter and ebpf_exporter.
#
# !IMPORTANT!
# This file is meant to be sourced, not executed directly:
#     source lib/exporters.sh
#
# It exposes functions that start/stop/inspect the two exporters under test,
# tracking PIDs in /tmp/*.pid files so that the orchestrator can manage them
# across multiple repetitions without leaking processes.

# Configuration
NODE_EXPORTER_BIN="${NODE_EXPORTER_BIN:-$HOME/node_exporter-1.10.2.linux-amd64/node_exporter}"
NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
NODE_EXPORTER_PIDFILE="${NODE_EXPORTER_PIDFILE:-/tmp/exporter-bench-node.pid}"
NODE_EXPORTER_LOG="${NODE_EXPORTER_LOG:-/tmp/exporter-bench-node.log}"

EBPF_EXPORTER_DIR="${EBPF_EXPORTER_DIR:-$HOME/ebpf_exporter}"
EBPF_EXPORTER_PORT="${EBPF_EXPORTER_PORT:-9435}"
EBPF_EXPORTER_PIDFILE="${EBPF_EXPORTER_PIDFILE:-/tmp/exporter-bench-ebpf.pid}"
EBPF_EXPORTER_LOG="${EBPF_EXPORTER_LOG:-/tmp/exporter-bench-ebpf.log}"

# List of ebpf_exporter configs to load.
EBPF_CONFIGS="${EBPF_CONFIGS:-timers,bpf-jit,syscalls,cfs-throttling,softirq-latency}"

# How long to wait for an exporter's /metrics endpoint to come up.
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-10}"
 
# How long to wait for graceful (SIGTERM) shutdown before escalating to SIGKILL.
SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-5}"

# Internal Helpers

# log_info writes a status line to stderr so it doesn't pollute captured stdout.
_log_info() { echo "[exporters] $*" >&2; }
_log_warn() { echo "[exporters][WARN] $*" >&2; }
_log_err()  { echo "[exporters][ERROR] $*" >&2; }

# wait_for_endpoint polls a URL until it returns HTTP 200 or timeout expires.
# Args: $1 = url, $2 = timeout in seconds.
# Returns: 0 if endpoint became ready, 1 on timeout.
wait_for_endpoint() {
    local url="$1"
    local timeout="$2"
    local elapsed=0
 
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -sS --max-time 1 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null \
            | grep -q '^200$'; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    return 1
}

# pid_alive checks whether a PID is currently running.
# Args: $1 = pid.
pid_alive() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# read_pidfile prints the PID stored in a pidfile, or empty string.
read_pidfile() {
    local pidfile="$1"
    [ -f "$pidfile" ] && cat "$pidfile" 2>/dev/null
}

# stop_pid sends SIGTERM, waits up to SHUTDOWN_TIMEOUT_SEC, then SIGKILL if needed.
# Args: $1 = pid, $2 = label (for logging), $3 = "sudo" if the process needs sudo to kill.
stop_pid() {
    local pid="$1"
    local label="$2"
    local need_sudo="${3:-}"
    local kill_cmd="kill"
    [ "$need_sudo" = "sudo" ] && kill_cmd="sudo kill"
 
    if ! pid_alive "$pid"; then
        return 0
    fi
 
    _log_info "stopping $label (pid=$pid) with SIGTERM"
    $kill_cmd -TERM "$pid" 2>/dev/null || true
 
    local elapsed=0
    while [ "$elapsed" -lt "$SHUTDOWN_TIMEOUT_SEC" ]; do
        if ! pid_alive "$pid"; then
            _log_info "$label stopped cleanly"
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
 
    _log_warn "$label did not exit in ${SHUTDOWN_TIMEOUT_SEC}s, escalating to SIGKILL"
    $kill_cmd -KILL "$pid" 2>/dev/null || true
    sleep 0.5
 
    if pid_alive "$pid"; then
        _log_err "$label survived SIGKILL — manual intervention needed"
        return 1
    fi
    return 0
}

# Public: node_exporter

start_node_exporter() {
    if is_node_exporter_running; then
        _log_warn "node_exporter already running (pid=$(read_pidfile "$NODE_EXPORTER_PIDFILE")), skipping start"
        return 0
    fi
 
    if [ ! -x "$NODE_EXPORTER_BIN" ]; then
        _log_err "node_exporter binary not executable: $NODE_EXPORTER_BIN"
        return 1
    fi
 
    _log_info "starting node_exporter on :$NODE_EXPORTER_PORT"
    "$NODE_EXPORTER_BIN" \
        --web.listen-address=":$NODE_EXPORTER_PORT" \
        > "$NODE_EXPORTER_LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$NODE_EXPORTER_PIDFILE"
 
    if wait_for_endpoint "http://localhost:$NODE_EXPORTER_PORT/metrics" "$STARTUP_TIMEOUT_SEC"; then
        _log_info "node_exporter ready (pid=$pid)"
        return 0
    else
        _log_err "node_exporter did not become ready within ${STARTUP_TIMEOUT_SEC}s; see $NODE_EXPORTER_LOG"
        return 1
    fi
}

stop_node_exporter() {
    local pid
    pid=$(read_pidfile "$NODE_EXPORTER_PIDFILE")
    if [ -z "$pid" ]; then
        return 0
    fi
    stop_pid "$pid" "node_exporter"
    rm -f "$NODE_EXPORTER_PIDFILE"
}
 
is_node_exporter_running() {
    local pid
    pid=$(read_pidfile "$NODE_EXPORTER_PIDFILE")
    pid_alive "$pid"
}

# Public: ebpf_explorer

start_ebpf_exporter() {
    if is_ebpf_exporter_running; then
        _log_warn "ebpf_exporter already running (pid=$(read_pidfile "$EBPF_EXPORTER_PIDFILE")), skipping start"
        return 0
    fi
 
    local bin="$EBPF_EXPORTER_DIR/ebpf_exporter"
    if [ ! -x "$bin" ]; then
        _log_err "ebpf_exporter binary not executable: $bin"
        return 1
    fi
 
    _log_info "starting ebpf_exporter on :$EBPF_EXPORTER_PORT with configs: $EBPF_CONFIGS"
 
    # Run with sudo because eBPF program loading needs CAP_BPF + CAP_PERFMON.
    (
        cd "$EBPF_EXPORTER_DIR" && \
        sudo --background nohup ./ebpf_exporter \
            --config.dir=examples \
            --config.names="$EBPF_CONFIGS" \
            --web.listen-address=":$EBPF_EXPORTER_PORT" \
            > "$EBPF_EXPORTER_LOG" 2>&1
    )
 
    # When invoked through sudo, $! refers to the sudo wrapper, not to the
    # actual ebpf_exporter process. Resolve the real PID via pgrep.
    sleep 1
    local pid
    pid=$(pgrep -f "ebpf_exporter --config.dir=examples" | head -n1)
    if [ -z "$pid" ]; then
        _log_err "could not locate ebpf_exporter PID after start; see $EBPF_EXPORTER_LOG"
        return 1
    fi
    echo "$pid" > "$EBPF_EXPORTER_PIDFILE"
 
    if wait_for_endpoint "http://localhost:$EBPF_EXPORTER_PORT/metrics" "$STARTUP_TIMEOUT_SEC"; then
        _log_info "ebpf_exporter ready (pid=$pid)"
        return 0
    else
        _log_err "ebpf_exporter did not become ready within ${STARTUP_TIMEOUT_SEC}s; see $EBPF_EXPORTER_LOG"
        return 1
    fi
}
 
stop_ebpf_exporter() {
    local pid
    pid=$(read_pidfile "$EBPF_EXPORTER_PIDFILE")
    if [ -z "$pid" ]; then
        return 0
    fi
    stop_pid "$pid" "ebpf_exporter" "sudo"
    rm -f "$EBPF_EXPORTER_PIDFILE"
}
 
is_ebpf_exporter_running() {
    local pid
    pid=$(read_pidfile "$EBPF_EXPORTER_PIDFILE")
    pid_alive "$pid"
}
 
# Public: convenience
 
stop_all_exporters() {
    stop_node_exporter
    stop_ebpf_exporter
}
