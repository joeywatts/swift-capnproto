# Security guide

Treat every message, schema, and RPC peer as hostile unless the application has
authenticated it separately. The checked APIs are the public default; the
package exposes no unchecked wire reader.

## Published limits

| Boundary | Default | Configuration |
| --- | ---: | --- |
| Reader traversal | 8,388,608 words | `ReaderOptions.traversalLimitInWords` |
| Reader nesting | 64 levels | `ReaderOptions.nestingLimit` |
| Stream segments | 512 | `FramingOptions.maximumSegments` |
| Stream payload | 8,388,608 words | `FramingOptions.maximumTotalWords` |
| Packed expansion | 67,108,864 bytes | `PackedDecoder.maximumOutputBytes` initializer |
| Builder segments | 512 | `BuilderOptions.maximumSegments` |
| Builder allocation | 8,388,608 words | `BuilderOptions.maximumTotalWords` |
| Schema source | 16 MiB per file | `CompilerConfiguration.maximumSourceBytes` |
| Schema import graph | 1,024 files | `CompilerConfiguration.maximumFiles` |
| RPC message | 1,048,576 words | `TwoPartyRPCConnection.maximumMessageWords` initializer |
| Capability table | 65,536 live entries | `CapabilityTable.maximumEntries` initializer |
| RPC validation tables | 65,536 per category | `RPCValidationLimits` |
| RPC connection tables | 65,536 per connection | `TwoPartyRPCConnection.maximumTableEntries` initializer |

Set tighter values for application-specific protocols. A limit is inclusive:
an input exactly at the configured value is accepted, and the next unit is
rejected before allocation or state mutation. Invalid integer conversions and
size arithmetic throw deterministic errors.

Unexpected Swift error descriptions can contain paths or application data.
Two-party RPC therefore sends the fixed `remote call failed` reason by default.
Throw `RemoteException` to deliberately publish a safe reason. The opt-in
`.localDescription` disclosure policy is intended only for trusted debugging.

The committed mutation corpus, pinned upstream seeds, Address Sanitizer job,
and boundary tests are release requirements. Report security issues privately
to the maintainers rather than attaching sensitive payloads to a public issue.
