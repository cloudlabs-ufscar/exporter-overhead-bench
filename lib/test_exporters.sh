#!/usr/bin/env bash
# test_exporters.sh — smoke test for lib/exporters.sh.
#
# Exercises the lifecycle functions in sequence and validates that each
# exporter actually serves /metrics. Not a unit test — it touches the real
# system (starts processes, listens on ports).
#
# Usage: ./lib/test_exporters.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./exporters.sh
source "$SCRIPT_DIR/exporters.sh"

PASS=0
FAIL=0

check() {
    local label="$1"
    local cond="$2"
    if [ "$cond" = "0" ]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== test_exporters.sh ==="
echo

echo "--- Phase 1: clean slate ---"
stop_all_exporters
is_node_exporter_running; check "node_exporter not running before start" $?
is_ebpf_exporter_running; check "ebpf_exporter not running before start" $?
echo

echo "--- Phase 2: node_exporter lifecycle ---"
start_node_exporter
check "start_node_exporter returns 0" $?
is_node_exporter_running; check "is_node_exporter_running returns true" $?

curl -sS --max-time 2 -o /dev/null "http://localhost:${NODE_EXPORTER_PORT:-9100}/metrics"
check "node_exporter /metrics responds" $?

stop_node_exporter
check "stop_node_exporter returns 0" $?
is_node_exporter_running; if [ $? -ne 0 ]; then check "is_node_exporter_running returns false after stop" 0; else check "is_node_exporter_running returns false after stop" 1; fi
echo

echo "--- Phase 3: ebpf_exporter lifecycle ---"
start_ebpf_exporter
check "start_ebpf_exporter returns 0" $?
is_ebpf_exporter_running; check "is_ebpf_exporter_running returns true" $?

curl -sS --max-time 2 -o /dev/null "http://localhost:${EBPF_EXPORTER_PORT:-9435}/metrics"
check "ebpf_exporter /metrics responds" $?

stop_ebpf_exporter
check "stop_ebpf_exporter returns 0" $?
is_ebpf_exporter_running; if [ $? -ne 0 ]; then check "is_ebpf_exporter_running returns false after stop" 0; else check "is_ebpf_exporter_running returns false after stop" 1; fi
echo

echo "--- Phase 4: idempotency ---"
stop_all_exporters
check "stop_all_exporters when nothing running returns 0" $?
echo

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
