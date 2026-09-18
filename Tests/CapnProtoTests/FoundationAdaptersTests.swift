import Foundation
import Testing

@testable import CapnProto

@Test func foundationDataAdaptersRoundTripFramedAndPackedMessages() throws {
    let message = try MessageBuilder()
    _ = try message.setRootData([1, 2, 3, 4])

    let framed = try message.framedData
    let reader = try MessageReader(framedData: framed)
    #expect(try reader.rootData().data == Data([1, 2, 3, 4]))
    #expect(try MessageFraming.decode(framed).dataSegments.count == message.segmentCount)

    let packed = try message.packedFramedData
    #expect(try PackedEncoding.unpack(packed) == framed)
}

@Test func exactFrameConvenienceRejectsTrailingMessages() throws {
    let message = try MessageBuilder()
    _ = try message.setRootText("one")
    let bytes = try message.framedBytes

    #expect(throws: Never.self) {
        _ = try MessageReader(framedBytes: bytes)
    }
    #expect(throws: CapnProtoError.invalidFrame) {
        _ = try MessageReader(framedBytes: bytes + bytes)
    }
}
