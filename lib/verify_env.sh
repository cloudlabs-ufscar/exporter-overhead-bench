#!/usr/bin/env bash
# verify_env.sh - preflight check for the benchmarking environment.
#
# Validates that all binaries, kernel features and services required by
# the experiment scripts are present.

set -u

# Configuration (override via environment)
NODE_EXPORTER_BIN="${NODE_EXPORTER_BIN:-$HOME/node_exporter-1.10.2.linux-amd64/node_exporter}"
EBPF_EXPORTER_DIR="${EBPF_EXPORTER_DIR:-$HOME/ebpf_exporter}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
MIN_KERNEL_MAJOR=5
MIN_KERNEL_MINOR=8

# Helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

errors=0
warnings=0

ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; warnings=$((warnings + 1)); }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; errors=$((errors + 1)); }
info()  { echo -e "[INFO]  $*"; }

# Checks

check_command() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "command '$cmd' available at $(command -v "$cmd")"
    else
        fail "command '$cmd' not found in PATH"
    fi
}

check_kernel_version() {
    local release major minor
    release=$(uname -r)
    major=$(echo "$release" | cut -d. -f1)
    minor=$(echo "$release" | cut -d. -f2)
 
    if [ "$major" -gt "$MIN_KERNEL_MAJOR" ] || \
       { [ "$major" -eq "$MIN_KERNEL_MAJOR" ] && [ "$minor" -ge "$MIN_KERNEL_MINOR" ]; }; then
        ok "kernel $release (>= ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR})"
    else
        fail "kernel $release is too old (minimum ${MIN_KERNEL_MAJOR}.${MIN_KERNEL_MINOR})"
    fi
}

check_btf() {
    local btf=/sys/kernel/btf/vmlinux
    if [ -r "$btf" ]; then
        local size
        size=$(stat -c%s "$btf")
        ok "BTF present at $btf (${size} bytes)"
    else
        fail "BTF not found at $btf — kernel was not built with CONFIG_DEBUG_INFO_BTF"
    fi
}
 
check_node_exporter() {
    if [ -x "$NODE_EXPORTER_BIN" ]; then
        ok "node_exporter binary at $NODE_EXPORTER_BIN"
    else
        fail "node_exporter binary not executable at $NODE_EXPORTER_BIN (override with NODE_EXPORTER_BIN env var)"
    fi
}
 
check_ebpf_exporter() {
    local bin="$EBPF_EXPORTER_DIR/ebpf_exporter"
    local examples="$EBPF_EXPORTER_DIR/examples"
    if [ -x "$bin" ]; then
        ok "ebpf_exporter binary at $bin"
    else
        fail "ebpf_exporter binary not executable at $bin (override with EBPF_EXPORTER_DIR env var)"
    fi
    if [ -d "$examples" ]; then
        local n
        n=$(find "$examples" -maxdepth 1 -name '*.bpf.o' | wc -l)
        if [ "$n" -gt 0 ]; then
            ok "ebpf_exporter examples directory has $n compiled .bpf.o files"
        else
            fail "ebpf_exporter examples/ has no .bpf.o files — programs not compiled"
        fi
    else
        fail "ebpf_exporter examples directory not found at $examples"
    fi
}
 
check_prometheus() {
    local resp
    resp=$(curl -sS --max-time 3 "${PROMETHEUS_URL}/-/healthy" 2>&1)
    if echo "$resp" | grep -q "Healthy"; then
        ok "Prometheus healthy at $PROMETHEUS_URL"
    else
        fail "Prometheus not healthy at $PROMETHEUS_URL (response: $resp)"
    fi
}
 
check_root_cap() {
    # ebpf_exporter needs CAP_BPF + CAP_PERFMON (or root) to load programs.
    # We don't require running this script as root, but we warn if sudo is
    # not available without password (the orchestrator will need it).
    if sudo -n true 2>/dev/null; then
        ok "passwordless sudo available (needed to start ebpf_exporter)"
    else
        warn "sudo requires password — orchestrator will prompt or fail in unattended runs"
    fi
}

# Main
echo "=== Environment verification for exporter-overhead-bench ==="
echo
 
info "Checking required commands..."
for cmd in curl jq bc stress-ng pgrep pkill awk sed; do
    check_command "$cmd"
done
echo

info "Checking exporter binaries..."
check_node_exporter
check_ebpf_exporter
echo

info "Checking Prometheus..."
check_prometheus
echo

info "Checking privileges..."
check_root_cap
echo

# Summary
echo "=== Summary ==="
echo "Errors: $errors"
echo "Warnings: $warnings"

if [ "$errors" -gt 0 ]; then
    echo -e "${RED}Environment is NOT ready. Fix the failures above before running experiments.${NC}"
    exit 1
fi

if [ "$warnings" -gt 0 ]; then
    echo -e "${YELLOW}Environment is functional but has warnings.${NC}"
fi

echo -e "${GREEN}Environment is ready.${NC}"
exit 0