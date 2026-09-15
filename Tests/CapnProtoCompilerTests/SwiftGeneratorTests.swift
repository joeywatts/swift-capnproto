import CapnProto
import CapnProtoCompiler
import CapnProtoConformance
import CapnProtoGeneratedFixtures
import CapnProtoRPC
import CapnProtoSchema
import Foundation
import Testing

@Test func emitsDeterministicRequestedFilesNestedScopesAndEscapedNames() throws {
    let request = try loadRequest("codegen-request")
    let first = try SwiftGenerator().generate(request)
    let second = try SwiftGenerator().generate(request)
    #expect(first == second)
    #expect(first.map(\.path) == ["keywords.capnp.swift", "import-user.capnp.swift"])

    let keywords = try #require(first.first?.contents)
    #expect(keywords.contains("public enum `Any`"))
    #expect(keywords.contains("    public enum `Protocol`"))
    #expect(keywords.contains("public struct Type_"))
    #expect(!first.map(\.path).contains("import-base.capnp.swift"))
}

// Ported generated-API behavior from capnproto 3a82de9b39736a2625f03c93b2b7c50642dd5b25:
// encoding-test.c++ Groups/InterleavedGroups/Unions and test.capnp TestAnyPointer/TestGenerics.
@Test func generatedUnionsGroupsNestedListsGenericsAndAnyPointersRoundTrip() throws {
    let message = try MessageBuilder()
    let builder = try Advanced.initRoot(in: message)
    try builder.setNestedList([[1, 2], [], [UInt16.max]])
    try builder.initNested().setValue(0xfeed_face)
    try builder.metadata.setCount(44)
    try builder.metadata.setLabel("outside union")
    try builder.setOutsideFlag(true)
    let nestedElementMessage = try MessageBuilder()
    let nestedElement = try Advanced.Nested.initRoot(in: nestedElementMessage)
    try nestedElement.setValue(77)
    try builder.setNestedStructList([
        [Advanced.Nested.Reader(try nestedElementMessage.asReader().rootStruct())], [],
    ])

    let pointerStruct = try builder.payload.initStruct(dataWords: 1, pointerCount: 0)
    try pointerStruct.setInteger(atByte: 0, to: UInt64(123))
    let typedList = try builder.typed.initList(elementSize: .twoBytes, count: 2)
    try typedList.setInteger(at: 0, to: UInt16(7))
    try typedList.setInteger(at: 1, to: UInt16(8))

    let erasedTextMessage = try MessageBuilder()
    _ = try erasedTextMessage.setRootText("erased")
    try builder.setPayload(erasedTextMessage.asReader().rootAnyPointer())
    let erasedStructMessage = try MessageBuilder()
    let erasedStruct = try erasedStructMessage.initRootStruct(dataWords: 1, pointerCount: 0)
    try erasedStruct.setInteger(atByte: 0, to: UInt64(456))
    try builder.setAnyStruct(erasedStructMessage.asReader().rootStruct())
    let erasedListMessage = try MessageBuilder()
    let erasedList = try erasedListMessage.initRootList(elementSize: .byte, count: 2)
    try erasedList.setInteger(at: 0, to: UInt8(10))
    try erasedList.setInteger(at: 1, to: UInt8(11))
    try builder.setAnyList(erasedListMessage.asReader().rootList())

    try builder.setText("discarded")
    try builder.setNumber(42)
    var reader = Advanced.Reader(try message.asReader().rootStruct())
    #expect(try !reader.hasText)
    guard case .number(let number) = try reader.which else {
        Issue.record("expected number union member")
        return
    }
    #expect(number == 42)

    let details = try builder.selectDetails()
    try details.setFlag(true)
    try details.setNote("selected group")
    reader = Advanced.Reader(try message.asReader().rootStruct())
    guard case .details(let selected) = try reader.which else {
        Issue.record("expected details union member")
        return
    }
    #expect(try selected.flag)
    #expect(try selected.note == "selected group")
    #expect(try reader.nestedList == [[1, 2], [], [UInt16.max]])
    #expect(try reader.nested.value == 0xfeed_face)
    #expect(try reader.nestedStructList.first?.first?.value == 77)
    #expect(try reader.nestedStructList.last?.isEmpty == true)
    #expect(try reader.metadata.count == 44)
    #expect(try reader.metadata.label == "outside union")
    #expect(try reader.outsideFlag)
    #expect(try reader.payload.asText().string == "erased")
    #expect(try reader.typed.asList().integer(at: 1, as: UInt16.self) == 8)
    let genericList = Advanced.Generic<CapnProtoAnyList>.Reader(reader)
    #expect(try genericList.typed.integer(at: 0, as: UInt16.self) == 7)
    #expect(try reader.anyStruct.integer(atByte: 0, as: UInt64.self) == 456)
    #expect(try reader.anyList.integer(at: 1, as: UInt8.self) == 11)

    try builder.setUnknownDiscriminant(65_000)
    reader = Advanced.Reader(try message.asReader().rootStruct())
    guard case .unknown(let tag) = try reader.which else {
        Issue.record("expected unknown union discriminant")
        return
    }
    #expect(tag == 65_000)
    #expect(try reader.details.note == "selected group")

    let genericBuilder = Advanced.Generic<CapnProtoText>.Builder(builder)
    try genericBuilder.setTyped("typed generic")
    reader = Advanced.Reader(try message.asReader().rootStruct())
    #expect(try Advanced.Generic<CapnProtoText>.Reader(reader).typed == "typed generic")
    #expect(Advanced.genericParameters == ["T"])

    let brandedMessage = try MessageBuilder()
    let branded = try Branded.initRoot(in: brandedMessage)
    try branded.initTextBox().setNestedList([[9]])
    #expect(try Branded.Reader(brandedMessage.asReader().rootStruct()).textBox.nestedList == [[9]])
}

@Test(arguments: ["actor", "protocol", "extension", "repeat", "ordinaryName", "Type"])
func identifierEscaping(_ name: String) {
    let result = swiftIdentifier(name)
    let expected = name == "ordinaryName" ? name : (name == "Type" ? "Type_" : "`\(name)`")
    #expect(result == expected)
}

// API-shape coverage for capability-test.c++ and rpc-test.c++ at upstream
// commit 3a82de9b39736a2625f03c93b2b7c50642dd5b25.
@Test func generatedInterfacesExposeClientsServersInheritanceAndStreaming() async throws {
    #expect(Base.Methods.ping.interfaceID == Base.schemaID)
    #expect(Base.Methods.ping.methodID == 0)
    #expect(!Base.Methods.ping.isStreaming)
    #expect(Child.superclassIDs == [Base.schemaID])
    #expect(Child.Methods.call.methodID == 0)
    #expect(Child.Methods.streamIt.methodID == 1)
    #expect(Child.Methods.streamIt.isStreaming)

    let paramsMessage = try MessageBuilder()
    let params = try Base.PingParams.initRoot(in: paramsMessage)
    try params.setValue(123)
    let client = Base.Client(CapabilityClient(target: GeneratedCallTarget()))
    let response = try await client.ping(
        Base.PingParams.Reader(try paramsMessage.asReader().rootStruct()))
    #expect(try response.text == "response 123")

    let _: any Child.Server = GeneratedChildServer()
    let local = Child.client(GeneratedChildServer())
    let requestMessage = try MessageBuilder()
    let requestBuilder = try Advanced.initRoot(in: requestMessage)
    try requestBuilder.setNumber(77)
    let request = Advanced.Reader(try requestMessage.asReader().rootStruct())
    let callMessage = try MessageBuilder()
    let callParams = try Child.CallParams.initRoot(in: callMessage)
    try callParams.setRequest(request)
    let callResult = try await local.call(
        Child.CallParams.Reader(try callMessage.asReader().rootStruct()))
    #expect(try callResult.response.number == 77)

    let inheritedMessage = try MessageBuilder()
    let inheritedParams = try Base.PingParams.initRoot(in: inheritedMessage)
    try inheritedParams.setValue(321)
    let inheritedPipeline = local.asBase.pingRequest(
        Base.PingParams.Reader(try inheritedMessage.asReader().rootStruct()))
    let inheritedResult = try await inheritedPipeline.response()
    #expect(try inheritedResult.text == "321")

    let streamMessage = try MessageBuilder()
    let streamParams = try Child.StreamItParams.initRoot(in: streamMessage)
    try streamParams.setChunk([1, 2, 3])
    try await local.streamIt(
        Child.StreamItParams.Reader(try streamMessage.asReader().rootStruct()))

    let holderMessage = try MessageBuilder()
    let holderBuilder = try CapabilityHolder.initRoot(in: holderMessage)
    let serializedClient = Child.Client(CapabilityClient(tableIndex: 7))
    try holderBuilder.setService(serializedClient)
    try holderBuilder.setServices([serializedClient, Child.Client(CapabilityClient(tableIndex: 9))])
    let holder = CapabilityHolder.Reader(try holderMessage.asReader().rootStruct())
    #expect(try holder.hasService)
    #expect(try holder.service.raw.tableIndex == 7)
    #expect(try holder.services.map(\.raw.tableIndex) == [7, 9])
}

@Test func sourceLocatedGeneratorErrorsHaveStableDiagnostics() {
    let error = SwiftGeneratorError.sourceLocated(
        source: "broken.capnp", startByte: 12, endByte: 19, detail: "node discriminant 99")
    #expect(error.description == "broken.capnp:bytes 12-19: node discriminant 99")
}

private final class GeneratedCallTarget: CapabilityCallTarget {
    func call(_ method: CapabilityMethodDescriptor, params: StructReader) async throws
        -> StructReader
    {
        #expect(method == Base.Methods.ping)
        let value = try Base.PingParams.Reader(params).value
        let message = try MessageBuilder()
        let result = try Base.PingResults.initRoot(in: message)
        try result.setText("response \(value)")
        return try message.asReader().rootStruct()
    }
}

private struct GeneratedChildServer: Child.Server {
    func ping(_ params: Base.PingParams.Reader, results: Base.PingResults.Builder) async throws {
        try results.setText("\(try params.value)")
    }

    func call(_ params: Child.CallParams.Reader, results: Child.CallResults.Builder) async throws {
        try results.setResponse(try params.request)
    }

    func streamIt(_ params: Child.StreamItParams.Reader) async throws {
        _ = try params.chunk
    }
}

private func loadRequest(_ name: String) throws -> Schema.CodeGeneratorRequest {
    let url = try #require(
        Bundle.module.url(
            forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
    return try Schema.CodeGeneratorRequest(framedBytes: Array(try Data(contentsOf: url)))
}

@Test func generatedReadersAndBuildersCoverValuesDefaultsListsAndUnknownEnums() throws {
    let message = try MessageBuilder()
    let builder = try TestAllTypes.initRoot(in: message)
    try builder.setBoolField(true)
    try builder.setInt8Field(-8)
    try builder.setInt16Field(-16)
    try builder.setInt32Field(-123_456)
    try builder.setInt64Field(-64)
    try builder.setUInt8Field(8)
    try builder.setUInt16Field(16)
    try builder.setUInt32Field(32)
    try builder.setUInt64Field(UInt64.max)
    try builder.setFloat32Field(1.25)
    try builder.setFloat64Field(-2.5)
    try builder.setTextField("typed")
    try builder.setDataField([0, 1, 255])
    let nested = try builder.initStructField()
    try nested.setTextField("nested")
    try builder.setEnumField(TestEnum(rawValue: 65_000))
    try builder.setVoidList([(), ()])
    try builder.setBoolList([true, false, true])
    try builder.setInt8List([-1, 2])
    try builder.setInt16List([-3, 4])
    try builder.setInt32List([1, -2, 3])
    try builder.setInt64List([-5, 6])
    try builder.setUInt8List([7, 8])
    try builder.setUInt16List([9, 10])
    try builder.setUInt32List([11, 12])
    try builder.setUInt64List([13, 14])
    try builder.setFloat32List([1.5, -2.5])
    try builder.setFloat64List([3.5, -4.5])
    try builder.setTextList(["one", "two"])
    try builder.setDataList([[1, 2], [3]])
    try builder.setEnumList([.foo, TestEnum(rawValue: 999)])

    let elementMessage = try MessageBuilder()
    let elementBuilder = try TestAllTypes.initRoot(in: elementMessage)
    try elementBuilder.setTextField("element")
    let elementReader = TestAllTypes.Reader(try elementMessage.asReader().rootStruct())
    try builder.setStructList([elementReader])

    let reader = TestAllTypes.Reader(try message.asReader().rootStruct())
    #expect(try reader.boolField)
    #expect(try reader.int8Field == -8)
    #expect(try reader.int16Field == -16)
    #expect(try reader.int32Field == -123_456)
    #expect(try reader.int64Field == -64)
    #expect(try reader.uInt8Field == 8)
    #expect(try reader.uInt16Field == 16)
    #expect(try reader.uInt32Field == 32)
    #expect(try reader.uInt64Field == UInt64.max)
    #expect(try reader.float32Field == 1.25)
    #expect(try reader.float64Field == -2.5)
    #expect(try reader.textField == "typed")
    #expect(try reader.dataField == [0, 1, 255])
    #expect(try reader.structField.textField == "nested")
    #expect(try reader.enumField.rawValue == 65_000)
    #expect(try reader.voidList.count == 2)
    #expect(try reader.boolList == [true, false, true])
    #expect(try reader.int8List == [-1, 2])
    #expect(try reader.int16List == [-3, 4])
    #expect(try reader.int32List == [1, -2, 3])
    #expect(try reader.int64List == [-5, 6])
    #expect(try reader.uInt8List == [7, 8])
    #expect(try reader.uInt16List == [9, 10])
    #expect(try reader.uInt32List == [11, 12])
    #expect(try reader.uInt64List == [13, 14])
    #expect(try reader.float32List == [1.5, -2.5])
    #expect(try reader.float64List == [3.5, -4.5])
    #expect(try reader.textList == ["one", "two"])
    #expect(try reader.dataList == [[1, 2], [3]])
    #expect(try reader.structList.first?.textField == "element")
    #expect(try reader.enumList.map(\.rawValue) == [0, 999])
    #expect(try reader.hasTextField)
    #expect(try reader.hasDataField)
    #expect(try reader.hasStructField)
    #expect(try reader.hasBoolList)
    #expect(constTestValue == "A const text test value.")

    let defaultsMessage = try MessageBuilder()
    _ = try TestDefaults.initRoot(in: defaultsMessage)
    let defaults = TestDefaults.Reader(try defaultsMessage.asReader().rootStruct())
    #expect(try defaults.boolField)
    #expect(try defaults.int8Field == -123)
    #expect(try defaults.int16Field == -12_345)
    #expect(try defaults.int32Field == -12_345_678)
    #expect(try defaults.int64Field == -123_456_789_012_345)
    #expect(try defaults.uInt8Field == 234)
    #expect(try defaults.uInt16Field == 45_678)
    #expect(try defaults.uInt32Field == 3_456_789_012)
    #expect(try defaults.uInt64Field == 12_345_678_901_234_567_890)
    #expect(try defaults.float32Field == 1_234.5)
    #expect(try defaults.float64Field == -1.23e47)
    #expect(try defaults.textField == "foo")
    #expect(try defaults.dataField == Array("bar".utf8))
    #expect(try defaults.structField.textField == "baz")
    #expect(try defaults.structField.dataField == Array("qux".utf8))
    #expect(try defaults.structField.structField.textField == "nested")
    #expect(try defaults.structField.structField.structField.textField == "really nested")
    #expect(try defaults.voidList.count == 6)
    #expect(try defaults.boolList == [true, false, false, true])
    #expect(try defaults.int8List == [111, -111])
    #expect(try defaults.int16List == [11_111, -11_111])
    #expect(try defaults.int32List == [111_111_111, -111_111_111])
    #expect(try defaults.int64List == [1_111_111_111_111_111_111, -1_111_111_111_111_111_111])
    #expect(try defaults.uInt8List == [111, 222])
    #expect(try defaults.uInt16List == [33_333, 44_444])
    #expect(try defaults.uInt32List == [3_333_333_333])
    #expect(try defaults.uInt64List == [11_111_111_111_111_111_111])
    let defaultFloat32 = try defaults.float32List
    #expect(defaultFloat32.prefix(3) == [5_555.5, .infinity, -.infinity])
    #expect(defaultFloat32.last?.isNaN == true)
    let defaultFloat64 = try defaults.float64List
    #expect(defaultFloat64.prefix(3) == [7_777.75, .infinity, -.infinity])
    #expect(defaultFloat64.last?.isNaN == true)
    #expect(try defaults.textList == ["plugh", "xyzzy", "thud"])
    #expect(
        try defaults.dataList == [
            Array("oops".utf8), Array("exhausted".utf8), Array("rfc3092".utf8),
        ])
    #expect(
        try defaults.structList.map { try $0.textField } == [
            "structlist 1", "structlist 2", "structlist 3",
        ])
    #expect(try defaults.enumField == .corge)
    #expect(try defaults.enumList == [.foo, .garply])
    #expect(try !defaults.hasTextField)
    #expect(try !defaults.hasDataField)
    #expect(try !defaults.hasStructField)
    #expect(try !defaults.hasBoolList)
}
