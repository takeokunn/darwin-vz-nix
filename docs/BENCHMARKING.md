# Reproducible VM benchmarks

The benchmark harness measures the existing CLI from the outside. It does not establish that this project is faster than another implementation. Publish the raw JSON, the exact revision, artifacts, hardware, and comparison baseline with any performance claim.

## Fixed conditions

Use an otherwise idle Apple Silicon host, the same macOS/Nix versions, power source, CPU and memory allocation, guest artifacts, workload, and iteration count. The default run collects 30 boot/SSH/shutdown samples and 10 build-workload samples; use more when results are noisy. The JSON records the revision, CLI and guest-artifact hashes, Nix and macOS versions, hardware model, non-secret VM parameters, individual samples, median, nearest-rank p95, and failure rate.

Metrics are defined as follows:

- `cold_boot`: CLI launch to successful SSH with a fresh harness-owned state directory and disk.
- `warm_boot`: CLI launch to successful SSH using the disk left by the cold boot and graceful shutdown.
- `ssh_ready`: the cold-boot interval until `darwin-vz-nix ssh ... true` succeeds.
- `shutdown`: graceful `stop` invocation through return of the foreground `start` process.
- `build_workload`: a successful representative `nix build --no-link nixpkgs#hello` inside the guest.

## Collection

VM and state deletion operations require two explicit opt-ins. The harness creates and deletes only its own `mktemp` directory. Command output and the workload command itself are never placed in the report.
Set `DARWIN_VZ_NIX_BENCHMARK_TMPDIR` to select its temporary parent directory. Otherwise the harness uses `TMPDIR`, or a private directory below `~/Library/Caches/darwin-vz-nix` when `TMPDIR` is unset; it never falls back to shared `/tmp` implicitly.

```sh
DARWIN_VZ_NIX_BENCHMARK_ALLOW_VM=1 scripts/benchmark.sh collect \
  --execute-vm \
  --cli ./result/bin/darwin-vz-nix \
  --kernel ./result-kernel/Image \
  --initrd ./result-initrd/initrd \
  --system ./result-system \
  --iterations 30 \
  --output candidate.json
```

The default workload is representative rather than exhaustive. Override it with `--workload-command`, but treat the command as potentially sensitive: it is passed to the guest and deliberately represented only as `representative_nix_build` in JSON.

## Baseline comparison

Without a threshold, comparison is informational and cannot produce a winning verdict:

```sh
scripts/benchmark.sh compare baseline.json candidate.json > comparison.json
```

An explicitly justified regression budget can fail automation. A positive change means the candidate is slower or has a higher failure rate:

```sh
scripts/benchmark.sh compare baseline.json candidate.json \
  --max-regression-percent 5 > comparison.json
```

Choose and document the threshold before observing the candidate. Comparison rejects unsupported schemas, missing statistics, insufficient samples, or differences in fixed environment metadata. Revision and CLI hashes identify each build and are expected to differ. A failure rate changing from zero to a positive value is always a regression when a threshold is supplied because a relative percentage is undefined; the report includes both `absolute_change` and `comparison_status`.
