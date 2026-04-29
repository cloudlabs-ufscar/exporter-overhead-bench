# exporter-overhead-bench
Benchmarking script for measuring the computational cost of Prometheus metric exporters on Linux systems, namely comparing `node_exporter`(`procfs` based, polling) and `ebpf_exporter`(kernel-side, event driven).

## Motivation
Excessive metric-extraction generates high system call volume, context switches, memory footprint and CPU pressure that can transform the monitoring system into hell.

This repository provides a reproducible experiment to quantify the cost of each exporter on the host machine, under simulated workloads (`stress_ng`), so deployment decisions can be made upon data.

## Methodology
The benchmark applies **system-wide differential measurement**, thus, total CPU consumed during a fixed interval of time is sampled with no exporter running to generate a baseline. Then, with each exporter running isolation under the same external load, giving the operational cost of each tool.

This approach is necessary because `ebpf_exporter` distributes part of its
work across all processes that trigger its attached tracepoints/kprobes, so
per-PID accounting (`/proc/<pid>/stat`) systematically underestimates its
real cost.

## Status
Work in progress. See open and merged PRs for the build sequence.

## Requirements

Linux kernel ≥ 5.8 with BTF enabled (`/sys/kernel/btf/vmlinux` present)
`node_exporter` binary
`ebpf_exporter` repository with pre-built .bpf.o files in `examples/`
Prometheus server reachable on localhost:9090
stress-ng, bc, jq, curl

ready.
Run `lib/verify_env.sh` before any experiment to confirm the environment is ready.

## License
GPL-3.0. See LICENSE.
