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

# check_eq <label> <actual_exit_code>
# passes when the actual exit code is 0.
check_eq() {
    local label="$1"
    local actual="$2"
    if [ "$actual" -eq 0 ]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label (exit=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

# check_ne <label> <actual_exit_code>
# passes when the actual exit code is NOT 0 (i.e. command "failed", which
# is the expected outcome for negative assertions like "is not running").
check_ne() {
    local label="$1"
    local actual="$2"
    if [ "$actual" -ne 0 ]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label (exit=$actual, expected non-zero)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== test_exporters.sh ==="
echo

echo "--- Phase 1: clean slate ---"
stop_all_exporters
is_node_exporter_running; check_ne "node_exporter not running before start" $?
is_ebpf_exporter_running; check_ne "ebpf_exporter not running before start" $?
echo

echo "--- Phase 2: node_exporter lifecycle ---"
start_node_exporter; check_eq "start_node_exporter returns 0" $?
is_node_exporter_running; check_eq "is_node_exporter_running returns true" $?
curl -sS --max-time 2 -o /dev/null "http://localhost:${NODE_EXPORTER_PORT:-9100}/metrics"; check_eq "node_exporter /metrics responds" $?
stop_node_exporter; check_eq "stop_node_exporter returns 0" $?
is_node_exporter_running; check_ne "is_node_exporter_running returns false after stop" $?
echo

echo "--- Phase 3: ebpf_exporter lifecycle ---"
start_ebpf_exporter; check_eq "start_ebpf_exporter returns 0" $?
is_ebpf_exporter_running; check_eq "is_ebpf_exporter_running returns true" $?
curl -sS --max-time 2 -o /dev/null "http://localhost:${EBPF_EXPORTER_PORT:-9435}/metrics"; check_eq "ebpf_exporter /metrics responds" $?
stop_ebpf_exporter; check_eq "stop_ebpf_exporter returns 0" $?
is_ebpf_exporter_running; check_ne "is_ebpf_exporter_running returns false after stop" $?
echo

echo "--- Phase 4: idempotency ---"
stop_all_exporters; check_eq "stop_all_exporters when nothing running returns 0" $?
echo

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]