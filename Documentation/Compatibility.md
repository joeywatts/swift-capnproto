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
configurable traversal-word and nesting limits.

Untyped builders support arena allocation, scalar/default-XOR fields, blobs,
primitive and composite lists, nested values, unions/groups, graph copy, and
same-arena orphan adoption. Standard stream framing supports scatter/gather,
concatenated and partial reads, and asynchronous byte chunks. Packed encoding is
incremental and expansion-bounded. Canonicalization emits one dense segment in
pointer preorder, truncates zero-valued struct sections, normalizes list padding,
and validates canonical form by exact bytes. These paths are cross-checked with
the pinned C++ oracle. Typed schemas and capability interface shapes are
generated; reflection and RPC execution remain scheduled for later milestones.
