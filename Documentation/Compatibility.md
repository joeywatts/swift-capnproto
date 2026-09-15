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

## Implemented wire compatibility

The checked reader accepts single- and multi-segment arrays containing near,
far, and double-far struct or list pointers. All standard list representations
(void, bit, 8/16/32/64-bit, pointer, and inline-composite) are supported, along
with Text and Data views. Reader-side schema evolution includes truncated or
expanded struct sections, default-value XOR, primitive/pointer list upgrades,
and preservation of unknown enum and union discriminant values as raw integers.

The reader copies its segment inputs and validates all targets before access.
Malformed inputs report deterministic `CapnProtoError` values and are bounded by
configurable traversal-word and nesting limits. Stream framing, packed encoding,
builders, generated types, schemas, and RPC remain scheduled for later
milestones.
