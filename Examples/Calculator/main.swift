import CapnProto
import CapnProtoRPC

let add = CapabilityMethodDescriptor(
    interfaceID: 0xca1c, methodID: 0, name: "add",
    paramStructID: 1, resultStructID: 2, isStreaming: false)
let calculator = CapabilityClient(
    target: LocalCapabilityTarget(interfaceIDs: [add.interfaceID], methods: [add]) { context in
        let lhs = try context.params.integer(atByte: 0, as: Int32.self)
        let rhs = try context.params.integer(atByte: 4, as: Int32.self)
        let response = try CapabilityResponseContext(dataWords: 1, pointerCount: 0)
        try response.results.setInteger(atByte: 0, to: lhs + rhs)
        return try response.finish()
    })

let request = try MessageBuilder()
let params = try request.initRootStruct(dataWords: 1, pointerCount: 0)
try params.setInteger(atByte: 0, to: Int32(20))
try params.setInteger(atByte: 4, to: Int32(22))
let result = try await calculator.call(add, params: request.asReader().rootStruct())
print(try result.integer(atByte: 0, as: Int32.self))
