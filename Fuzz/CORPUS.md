# Fuzz corpus

The pinned upstream revision does not publish a standalone corpus directory.
The message, packed, and schema-request fuzz entry points consume all eight committed binaries under
`Tests/InteropFixtures/generated`; those inputs were produced by the pinned
upstream implementation and cover raw, framed, packed, and multi-segment data.
The deterministic property tests additionally generate truncated, extended,
and arbitrary byte sequences from a recorded seed. `Fuzz/Seeds` contains small
explicit malformed inputs for direct command-line and sanitizer runs.

`Scripts/verify-fuzz-targets.sh` runs every upstream-derived seed through all
targets. Rejected syntax is an expected result; a trap, sanitizer report, hang,
or nonzero process result is a failure.
