import CapnProto
import Foundation

/// A protocol violation detected before the connection's capability tables are mutated.
public enum RPCProtocolError: Error, Equatable, Sendable {
    case malformedMessage(String)
    case unknownMessageVariant(UInt16)
    case unsupportedMessageVariant(String)
    case duplicateQuestion(UInt32)
    case unknownQuestion(UInt32)
    case duplicateReturn(UInt32)
    case unknownAnswer(UInt32)
    case unknownCapability(UInt32)
    case invalidReferenceCount
    case invalidTransform
    case unsupportedThirdPartyCapability
    case embargoMismatch(UInt32)
    case messageTooLarge
}

/// IDs visible to the protocol validator. Validation is transactional: callers
/// receive an updated copy only after the complete message has been checked.
public struct RPCWireValidationState: Equatable, Sendable {
    public var inboundQuestions: Set<UInt32> = []
    public var outboundQuestions: Set<UInt32> = []
    public var returnedQuestions: Set<UInt32> = []
    public var exports: Set<UInt32> = []
    public var imports: Set<UInt32> = []
    public var senderLoopbackEmbargoes: Set<UInt32> = []
    public var receiverLoopbackEmbargoes: Set<UInt32> = []

    public init() {}
}

public enum RPCWireValidator {
    /// Decodes exactly one stream-framed RPC message using conservative limits.
    public static func decode(
        _ bytes: [UInt8], maximumWords: Int = 1 << 20
    ) throws -> Message.Reader {
        do {
            let frame = try MessageFraming.decodePrefix(
                bytes, options: FramingOptions(maximumSegments: 64, maximumTotalWords: maximumWords))
            guard frame.byteCount == bytes.count else {
                throw RPCProtocolError.malformedMessage("trailing bytes")
            }
            return Message.Reader(
                try frame.reader(
                    options: ReaderOptions(
                        traversalLimitInWords: maximumWords, nestingLimit: 64
                    )
                ).rootStruct())
        } catch let error as RPCProtocolError {
            throw error
        } catch CapnProtoError.frameTooLarge {
            throw RPCProtocolError.messageTooLarge
        } catch {
            throw RPCProtocolError.malformedMessage(String(describing: error))
        }
    }

    /// Validates every referenced ID and union tag and commits transitions only
    /// after all nested fields have been inspected.
    public static func validate(
        _ message: Message.Reader, state: inout RPCWireValidationState
    ) throws {
        var next = state
        switch try message.which {
        case .bootstrap(let bootstrap):
            try beginInboundQuestion(try bootstrap.questionId, state: &next)
        case .call(let call):
            try validateTarget(try call.target, state: next)
            try validatePayload(try call.params, state: next)
            switch try call.sendResultsTo.which {
            case .caller, .yourself: break
            case .thirdParty: throw RPCProtocolError.unsupportedMessageVariant("third-party results")
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
            try beginInboundQuestion(try call.questionId, state: &next)
        case .return(let result):
            let id = try result.answerId
            guard next.outboundQuestions.contains(id) else {
                throw RPCProtocolError.unknownQuestion(id)
            }
            guard next.returnedQuestions.insert(id).inserted else {
                throw RPCProtocolError.duplicateReturn(id)
            }
            switch try result.which {
            case .results(let payload): try validatePayload(payload, state: next)
            case .exception, .canceled, .resultsSentElsewhere: break
            case .takeFromOtherQuestion(let other):
                guard next.outboundQuestions.contains(other), other != id else {
                    throw RPCProtocolError.unknownQuestion(other)
                }
            case .acceptFromThirdParty:
                throw RPCProtocolError.unsupportedMessageVariant("third-party return")
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
        case .finish(let finish):
            let id = try finish.questionId
            guard next.inboundQuestions.remove(id) != nil else {
                throw RPCProtocolError.unknownAnswer(id)
            }
        case .release(let release):
            let id = try release.id
            guard try release.referenceCount > 0 else {
                throw RPCProtocolError.invalidReferenceCount
            }
            guard next.exports.contains(id) else { throw RPCProtocolError.unknownCapability(id) }
        case .resolve(let resolve):
            let id = try resolve.promiseId
            guard next.imports.contains(id) else { throw RPCProtocolError.unknownCapability(id) }
            switch try resolve.which {
            case .cap(let descriptor): try validateDescriptor(descriptor, state: next)
            case .exception: break
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
        case .disembargo(let disembargo):
            switch try disembargo.context.which {
            case .senderLoopback(let id):
                guard next.senderLoopbackEmbargoes.remove(id) != nil else {
                    throw RPCProtocolError.embargoMismatch(id)
                }
            case .receiverLoopback(let id):
                try validateTarget(try disembargo.target, state: next)
                guard next.receiverLoopbackEmbargoes.insert(id).inserted else {
                    throw RPCProtocolError.embargoMismatch(id)
                }
            case .accept, .provide:
                throw RPCProtocolError.unsupportedMessageVariant("three-party embargo")
            case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
            }
        case .abort, .unimplemented:
            break
        case .obsoleteSave, .obsoleteDelete, .provide, .accept, .join:
            throw RPCProtocolError.unsupportedMessageVariant("three-party RPC")
        case .unknown(let tag):
            throw RPCProtocolError.unknownMessageVariant(tag)
        }
        state = next
    }

    public static func validateTarget(
        _ target: MessageTarget.Reader, state: RPCWireValidationState
    ) throws {
        switch try target.which {
        case .importedCap(let id):
            guard state.exports.contains(id) else { throw RPCProtocolError.unknownCapability(id) }
        case .promisedAnswer(let answer):
            let id = try answer.questionId
            guard state.inboundQuestions.contains(id) else {
                throw RPCProtocolError.unknownAnswer(id)
            }
            for operation in try answer.transform {
                switch try operation.which {
                case .noop, .getPointerField: break
                case .unknown: throw RPCProtocolError.invalidTransform
                }
            }
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
    }

    public static func validateDescriptor(
        _ descriptor: CapDescriptor.Reader, state: RPCWireValidationState
    ) throws {
        switch try descriptor.which {
        case .none, .senderHosted, .senderPromise: break
        case .receiverHosted(let id):
            guard state.exports.contains(id) else { throw RPCProtocolError.unknownCapability(id) }
        case .receiverAnswer(let answer):
            guard state.inboundQuestions.contains(try answer.questionId) else {
                throw RPCProtocolError.unknownAnswer(try answer.questionId)
            }
        case .thirdPartyHosted: throw RPCProtocolError.unsupportedThirdPartyCapability
        case .unknown(let tag): throw RPCProtocolError.unknownMessageVariant(tag)
        }
    }

    private static func validatePayload(
        _ payload: Payload.Reader, state: RPCWireValidationState
    ) throws {
        for descriptor in try payload.capTable { try validateDescriptor(descriptor, state: state) }
    }

    private static func beginInboundQuestion(
        _ id: UInt32, state: inout RPCWireValidationState
    ) throws {
        guard state.inboundQuestions.insert(id).inserted else {
            throw RPCProtocolError.duplicateQuestion(id)
        }
    }
}
