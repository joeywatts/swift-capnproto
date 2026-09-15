#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Operation: String {
    case decode
    case encode
}

enum StockTest: String {
    case simpleTest
    case textListTypeTest
    case uInt8DefaultValueTest
    case constTest
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

// Exit 127 is the capnp_test contract's intentional-skip result. Keeping all
// stock operation/case pairs explicit prevents newly-added harness cases from
// being mistaken for implemented behavior.
switch (operation, test) {
case (.decode, .simpleTest),
    (.decode, .textListTypeTest),
    (.decode, .uInt8DefaultValueTest),
    (.decode, .constTest),
    (.encode, .simpleTest),
    (.encode, .textListTypeTest),
    (.encode, .uInt8DefaultValueTest),
    (.encode, .constTest):
    exit(127)
}
