# Swift Cap'n Proto 1.0

Version 1.0 is the first stable release of the pure Swift serialization,
reflection, compiler, and Level 3 two-party RPC stack.

## Compatibility matrix

| Host | Architecture | Swift | Status |
| --- | --- | --- | --- |
| macOS 13+ | Apple Silicon | 6.2 | Supported, CI and sanitizer |
| Linux Ubuntu 24.04+ | AArch64 | 6.2 | Supported |
| Linux Ubuntu 24.04+ | x86-64 | 6.2 | Supported, CI and sanitizer |

The protocol baseline is Cap'n Proto 1.x commit
`3a82de9b39736a2625f03c93b2b7c50642dd5b25`; the language-neutral test baseline
is `kaos/capnp_test` commit `9aad1331857d2b02158cffdba4d664f71f7f81de`.
Checksums for generated release inputs are in `Release/1.0.0-CHECKSUMS`.
The tag workflow publishes the deterministic source archive and its
`SHA256SUMS` artifact; reproduce both with `Scripts/create-source-release.sh`.

Known deviations are the intentionally deferred JSON/text codecs, persistent
capabilities, membranes, WebSocket transport, Windows, three-party handoff, and
v2 protocol. Ancillary file-descriptor passing is not exposed by the Swift API.
See `Documentation/Performance.md` for benchmark methodology and release-asset
requirements, and `Documentation/Security.md` for audited resource ceilings.
