import CapnProto
import CapnProtoConformance
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum Operation: String {
    case decode
    case encode
    case roundtrip
}

enum StockTest: String {
    case simpleTest
    case textListTypeTest
    case uInt8DefaultValueTest
    case constTest
    case allTypesInterop
    case defaultsInterop
}

guard CommandLine.arguments.count == 3 else {
    exit(64)
}

guard
    let operation = Operation(rawValue: CommandLine.arguments[1]),
    let test = StockTest(rawValue: CommandLine.arguments[2])
else {
    exit(65)
}

do {
    switch operation {
    case .decode:
        let bytes = Array(FileHandle.standardInput.readDataToEndOfFile())
        let text: String
        switch test {
        case .simpleTest, .constTest:
            let value = try SimpleTestStruct.readRoot(from: bytes)
            text = "(int = \(try value.int), msg = \(String(reflecting: try value.msg)))"
        case .textListTypeTest:
            let value = try ListTest.readRoot(from: bytes)
            text =
                "(textList = [\(try value.textList.map(String.init(reflecting:)).joined(separator: ", "))])"
        case .uInt8DefaultValueTest:
            text = try describeDefaults(TestDefaults.readRoot(from: bytes))
        case .allTypesInterop, .defaultsInterop:
            exit(65)
        }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    case .encode:
        let message = try MessageBuilder()
        switch test {
        case .simpleTest:
            let value = try SimpleTestStruct.initRoot(in: message)
            try value.setInt(1_234_567_890)
            try value.setMsg("a short message...")
        case .textListTypeTest:
            let value = try ListTest.initRoot(in: message)
            try value.setTextList(["foo", "bar", "baz"])
        case .uInt8DefaultValueTest:
            let value = try TestDefaults.initRoot(in: message)
            try value.setUInt8Field(0)
        case .constTest:
            let value = try SimpleTestStruct.initRoot(in: message)
            try value.setMsg(constTestValue)
        case .allTypesInterop:
            try populateAllTypes(TestAllTypes.initRoot(in: message))
        case .defaultsInterop:
            _ = try TestDefaults.initRoot(in: message)
        }
        FileHandle.standardOutput.write(Data(try message.framedBytes))
    case .roundtrip:
        let bytes = Array(FileHandle.standardInput.readDataToEndOfFile())
        let message = try MessageBuilder()
        switch test {
        case .allTypesInterop:
            let source = try TestAllTypes.readRoot(from: bytes)
            let destination = try TestAllTypes.initRoot(in: message)
            try destination.raw.copyContent(from: source.raw)
        case .defaultsInterop:
            let source = try TestDefaults.readRoot(from: bytes)
            let destination = try TestDefaults.initRoot(in: message)
            try destination.raw.copyContent(from: source.raw)
        case .simpleTest, .textListTypeTest, .uInt8DefaultValueTest, .constTest:
            exit(65)
        }
        FileHandle.standardOutput.write(Data(try message.framedBytes))
    }
} catch {
    FileHandle.standardError.write(Data("capnp-test-swift: \(error)\n".utf8))
    exit(1)
}

private func describeDefaults(_ value: TestDefaults.Reader) throws -> String {
    let enumName: String
    switch try value.enumField.rawValue {
    case TestEnum.foo.rawValue: enumName = "foo"
    case TestEnum.bar.rawValue: enumName = "bar"
    case TestEnum.baz.rawValue: enumName = "baz"
    case TestEnum.qux.rawValue: enumName = "qux"
    case TestEnum.quux.rawValue: enumName = "quux"
    case TestEnum.corge.rawValue: enumName = "corge"
    case TestEnum.grault.rawValue: enumName = "grault"
    case TestEnum.garply.rawValue: enumName = "garply"
    default: enumName = "\(try value.enumField.rawValue)"
    }
    return "(voidField = void, boolField = \(try value.boolField), "
        + "int8Field = \(try value.int8Field), int16Field = \(try value.int16Field), "
        + "int32Field = \(try value.int32Field), int64Field = \(try value.int64Field), "
        + "uInt8Field = \(try value.uInt8Field), uInt16Field = \(try value.uInt16Field), "
        + "uInt32Field = \(try value.uInt32Field), uInt64Field = \(try value.uInt64Field), "
        + "float32Field = \(format(try value.float32Field)), "
        + "float64Field = \(format(try value.float64Field)), enumField = \(enumName), "
        + "interfaceField = void)"
}

private func format<T: BinaryFloatingPoint>(_ value: T) -> String {
    String(describing: value).replacingOccurrences(of: "e+", with: "e")
}

private func populateAllTypes(_ value: TestAllTypes.Builder) throws {
    try value.setBoolField(true)
    try value.setInt8Field(-8)
    try value.setInt16Field(-16)
    try value.setInt32Field(-123_456)
    try value.setInt64Field(-64)
    try value.setUInt8Field(8)
    try value.setUInt16Field(16)
    try value.setUInt32Field(32)
    try value.setUInt64Field(UInt64.max)
    try value.setFloat32Field(1.25)
    try value.setFloat64Field(-2.5)
    try value.setTextField("typed")
    try value.setDataField([0, 1, 255])
    try value.initStructField().setTextField("nested")
    try value.setEnumField(.grault)
    try value.setVoidList([(), ()])
    try value.setBoolList([true, false, true])
    try value.setInt8List([-1, 2])
    try value.setInt16List([-3, 4])
    try value.setInt32List([1, -2, 3])
    try value.setInt64List([-5, 6])
    try value.setUInt8List([7, 8])
    try value.setUInt16List([9, 10])
    try value.setUInt32List([11, 12])
    try value.setUInt64List([13, 14])
    try value.setFloat32List([1.5, -2.5])
    try value.setFloat64List([3.5, -4.5])
    try value.setTextList(["one", "two"])
    try value.setDataList([[1, 2], [3]])
    try value.setEnumList([.foo, .garply])
    try value.setInterfaceList([()])

    let elementMessage = try MessageBuilder()
    let element = try TestAllTypes.initRoot(in: elementMessage)
    try element.setTextField("element")
    try value.setStructList([TestAllTypes.Reader(try elementMessage.asReader().rootStruct())])
}
