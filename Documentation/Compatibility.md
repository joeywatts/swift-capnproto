# Compatibility baseline

The implementation targets the Cap'n Proto 1.x `master` protocol and schema
language as captured by `capnproto/capnproto` commit
`3a82de9b39736a2625f03c93b2b7c50642dd5b25`. Tests and schemas imported from
that revision are immutable and checksummed in `Tests/Upstream`.

The following features are intentionally outside the first stable release and
unsupported until promoted by a later roadmap revision:

- the incompatible Cap'n Proto v2 development protocol;
- JSON and text codecs;
- persistent capabilities and membranes; and
- WebSocket RPC.

The standard compiler remains a permitted development and CI oracle. No shipped
Swift target may link the upstream C or C++ implementation.
