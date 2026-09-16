# Performance

`Scripts/run-benchmarks.sh` builds with `-c release`, emits machine-readable
JSON, and compares nanoseconds per iteration with `Benchmarks/BASELINES.tsv`.
CI fails when any representative workload exceeds eight times its stored
baseline. The deliberately wide multiplier catches major algorithmic regressions
without treating shared-runner noise as correctness failure.

The five workloads are framed decode, repeated pointer/data traversal, arena
build, scatter/gather serialization flattening, and packed decode. Run with a
fixed workload using:

```sh
CAPNP_BENCHMARK_ITERATIONS=100000 Scripts/run-benchmarks.sh
```

The 1.0 profiling pass replaced byte-at-a-time endian loads with checked
unaligned native loads plus explicit little-endian conversion. This keeps the
same checked bounds path and is covered by deliberately unaligned and simulated
reverse-endian vectors. Arena limits and table sizing were changed only after
the representative baselines were recorded.

## Comparative release procedure

Release comparisons use the same 264-byte logical payload and iteration count.
Build Swift, the pinned C++ revision from `Tests/Upstream/BASELINES`, and the
current stable `capnproto-rust` release with optimization enabled. Record CPU,
OS, compiler versions, raw JSON/CSV, medians from five isolated runs, and ratios
in the release notes. Compare decode, traversal, build, serialize, and packed I/O;
do not combine compile time with execution time. Raw results are release assets,
so published numbers remain independently reproducible instead of being copied
into a source file without their environment.

`Scripts/run-comparative-benchmarks.sh` builds all three optimized drivers and
writes their machine-readable rows to `Benchmarks/comparison.jsonl` (or
`CAPNP_BENCHMARK_OUTPUT`). The 1.0 release candidate includes both peers. C++ establishes
the reference implementation cost; Rust supplies a mature memory-safe non-C++
implementation. Performance does not relax validation: all benchmarked Swift
entry points are the same checked public APIs used by applications.
