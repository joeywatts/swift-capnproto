import CapnProto
import CapnProtoRPC

let echo = CapabilityMethodDescriptor(
    interfaceID: 0xec40, methodID: 0, name: "echo",
    paramStructID: 1, resultStructID: 1, isStreaming: false)
let service = CapabilityClient(
    target: LocalCapabilityTarget(interfaceIDs: [echo.interfaceID], methods: [echo]) {
        $0.params
    })
let promised = CapabilityClient.makePromise()

let request = try MessageBuilder()
let value = try request.initRootStruct(dataWords: 1, pointerCount: 0)
try value.setInteger(atByte: 0, to: UInt32(42))

// The call is queued before the capability resolves, which is the ordering
// guarantee used by generated pipeline accessors.
let call = try promised.client.startCall(echo, params: request.asReader().rootStruct())
try promised.resolver.resolve(to: service)
let result = try await call.response()
print(try result.integer(atByte: 0, as: UInt32.self))
