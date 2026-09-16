# Security guide

All public readers validate bounds and checked arithmetic. Configure traversal,
nesting, segment, expansion, builder-allocation, compiler, and RPC table limits
for the application. Defaults are documented in `Documentation/Security.md`.

RPC redacts unexpected local errors by default. Throw a deliberate
`RemoteException` only when its reason is safe to disclose to a peer.
