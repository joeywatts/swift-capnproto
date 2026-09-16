# RPC tutorial

Define an interface in a schema, generate it, implement its `Server` protocol,
and wrap the implementation with the generated `client` function. For network
use, create matching `TwoPartyRPCConnection` instances over a
`NIOByteStreamTransport`; only the server supplies a bootstrap capability.

Generated non-streaming request methods return pipeline values immediately.
Calls through capability fields on that pipeline may be issued before the parent
response arrives. Keep the pipeline or response alive until dependent calls
finish, and call `cancel()` when abandoning work.

Applications should authenticate and encrypt the byte stream outside this
package. Set a message limit appropriate to the service and expose only
deliberately sanitized `RemoteException` reasons. See the runnable calculator
and pipelining examples under `Examples/`.
