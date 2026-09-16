# Migration and compatibility

The 1.0 API uses throwing initializers and accessors at all wire boundaries.
Callers migrating from prototypes should replace assumed-valid buffers with
`MessageFraming.decodePrefix`, pass explicit `ReaderOptions`, and retain the
returned reader rather than borrowing external storage.

Generated files should be regenerated with the same `capnp-swift` release as the
runtime. Unknown enum and union cases must not be exhaustively collapsed; retain
their raw values. RPC services should throw `RemoteException` for peer-visible
failures because arbitrary Swift errors are redacted by default.

Source-compatible additions are allowed in 1.x. Removed declarations, changed
wire semantics, and new protocol requirements wait for a new major version.
