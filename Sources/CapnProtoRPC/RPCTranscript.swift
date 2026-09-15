import Foundation

public struct RPCTranscriptEntry: Equatable, Sendable {
    public let bytes: [UInt8]
    public let expectedState: RPCWireValidationState?

    public init(bytes: [UInt8], expectedState: RPCWireValidationState? = nil) {
        self.bytes = bytes
        self.expectedState = expectedState
    }
}

public struct RPCTranscriptResult: Equatable, Sendable {
    public let states: [RPCWireValidationState]
    public let finalState: RPCWireValidationState
}

/// Replays captured wire messages without timing dependencies, checking the
/// complete table state after every transition.
public enum RPCTranscriptRunner {
    public static func replay(
        _ entries: [RPCTranscriptEntry],
        initialState: RPCWireValidationState = RPCWireValidationState(),
        maximumMessageWords: Int = 1 << 20
    ) throws -> RPCTranscriptResult {
        var state = initialState
        var states: [RPCWireValidationState] = []
        states.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            let message = try RPCWireValidator.decode(
                entry.bytes, maximumWords: maximumMessageWords)
            try RPCWireValidator.validate(message, state: &state)
            if let expected = entry.expectedState, expected != state {
                throw RPCTranscriptError.stateMismatch(index: index)
            }
            states.append(state)
        }
        return RPCTranscriptResult(states: states, finalState: state)
    }
}

public enum RPCTranscriptError: Error, Equatable, Sendable {
    case stateMismatch(index: Int)
}
