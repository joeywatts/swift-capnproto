# Public API review

The stable 1.0 surface consists of the products declared in `Package.swift`.
`CapnProto` deliberately exposes checked untyped readers/builders, framing,
packing, canonicalization, allocation policy, and resource options because
generated code and advanced applications require them. `CapnProtoSchema` exposes
schema metadata and dynamic values. `CapnProtoRPC` exposes capability and
connection abstractions; generated wire structs remain an implementation detail
despite residing in the module. `CapnProtoNIO` exposes transports only, and
`CapnProtoCompiler` exposes the native frontend and generator model.

Arena storage, pointer resolution, mutable reader state, transport mailboxes,
RPC table entries, parser state, and native layout IR are internal. The release
check rejects public declarations with those internal implementation names.
