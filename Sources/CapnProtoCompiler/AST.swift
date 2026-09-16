public struct SchemaFileSyntax: Equatable, Sendable {
    public var id: UInt64?
    public var declarations: [DeclarationSyntax]
    public let range: SourceRange

    public init(id: UInt64?, declarations: [DeclarationSyntax], range: SourceRange) {
        self.id = id
        self.declarations = declarations
        self.range = range
    }
}

public indirect enum DeclarationSyntax: Equatable, Sendable {
    case application(AnnotationUseSyntax)
    case `using`(UsingSyntax)
    case structure(StructSyntax)
    case enumeration(EnumSyntax)
    case interface(InterfaceSyntax)
    case constant(ConstantSyntax)
    case annotation(AnnotationDeclarationSyntax)
}

public struct UsingSyntax: Equatable, Sendable {
    public let name: String?
    public let target: TypeSyntax
    public let range: SourceRange
}

public struct StructSyntax: Equatable, Sendable {
    public let name: String
    public let id: UInt64?
    public let parameters: [String]
    public let annotations: [AnnotationUseSyntax]
    public let members: [StructMemberSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public indirect enum StructMemberSyntax: Equatable, Sendable {
    case field(FieldSyntax)
    case group(GroupSyntax)
    case union([StructMemberSyntax], annotations: [AnnotationUseSyntax], SourceRange)
    case namedUnion(GroupSyntax, ordinal: UInt16?)
    case declaration(DeclarationSyntax)
}

public struct FieldSyntax: Equatable, Sendable {
    public let name: String
    public let ordinal: UInt16
    public let type: TypeSyntax
    public let defaultValue: ValueSyntax?
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public struct GroupSyntax: Equatable, Sendable {
    public let name: String
    public let members: [StructMemberSyntax]
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public struct EnumSyntax: Equatable, Sendable {
    public let name: String
    public let id: UInt64?
    public let enumerants: [EnumerantSyntax]
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public struct EnumerantSyntax: Equatable, Sendable {
    public let name: String
    public let ordinal: UInt16
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public struct InterfaceSyntax: Equatable, Sendable {
    public let name: String
    public let id: UInt64?
    public let parameters: [String]
    public let superclasses: [TypeSyntax]
    public let annotations: [AnnotationUseSyntax]
    public let members: [InterfaceMemberSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public enum InterfaceMemberSyntax: Equatable, Sendable {
    case method(MethodSyntax)
    case declaration(DeclarationSyntax)
}

public struct MethodSyntax: Equatable, Sendable {
    public let name: String
    public let ordinal: UInt16
    public let typeParameters: [String]
    public let parameters: [ParameterSyntax]
    public let results: MethodResultsSyntax
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public enum MethodResultsSyntax: Equatable, Sendable {
    case parameters([ParameterSyntax])
    case named(TypeSyntax)
    case stream
}

public struct ParameterSyntax: Equatable, Sendable {
    public let name: String
    public let type: TypeSyntax
    public let defaultValue: ValueSyntax?
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
}

public struct ConstantSyntax: Equatable, Sendable {
    public let name: String
    public let type: TypeSyntax
    public let value: ValueSyntax
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public struct AnnotationDeclarationSyntax: Equatable, Sendable {
    public let name: String
    public let id: UInt64?
    public let type: TypeSyntax
    public let targets: [String]
    public let annotations: [AnnotationUseSyntax]
    public let range: SourceRange
    public let docComment: String?
}

public struct AnnotationUseSyntax: Equatable, Sendable {
    public let name: NameSyntax
    public let brandArguments: [TypeSyntax]
    public let value: ValueSyntax?
    public let range: SourceRange
}

public indirect enum TypeSyntax: Equatable, Sendable {
    case named(NameSyntax, arguments: [TypeSyntax])
    case list(TypeSyntax)
}

public struct NameSyntax: Equatable, Sendable {
    public enum Root: Equatable, Sendable {
        case relative
        case absolute
        case imported(String)
    }

    public let root: Root
    public let components: [String]
    public let range: SourceRange
}

public indirect enum ValueSyntax: Equatable, Sendable {
    case identifier(NameSyntax)
    case integer(UInt64)
    case negativeInteger(UInt64)
    case float(Double)
    case string(String)
    case data([UInt8])
    case embed(String)
    case list([ValueSyntax])
    case tuple([(String, ValueSyntax)])
    case void

    public static func == (lhs: ValueSyntax, rhs: ValueSyntax) -> Bool {
        switch (lhs, rhs) {
        case (.identifier(let a), .identifier(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.negativeInteger(let a), .negativeInteger(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.embed(let a), .embed(let b)): return a == b
        case (.list(let a), .list(let b)): return a == b
        case (.tuple(let a), .tuple(let b)):
            return a.count == b.count
                && zip(a, b).allSatisfy {
                    $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
                }
        case (.void, .void): return true
        default: return false
        }
    }
}
