import Foundation

/// L0 — valeur JSON typée et Sendable.
///
/// Remplace `[String: Any]` dans tous les nouveaux modules : un dictionnaire
/// non typé n'est ni Sendable ni Codable, et chaque `as?` est un mensonge
/// potentiel. Ici l'échec de conversion est explicite (`JSONConversionError`).
public enum JSONValue: Sendable, Hashable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(exactly: d)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue {
        object?[key] ?? .null
    }

    // MARK: - Conversions

    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: Int) { self = .int(value) }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: String) { self = .string(value) }
    public init(_ value: [JSONValue]) { self = .array(value) }
    public init(_ value: [String: JSONValue]) { self = .object(value) }

    /// Construit depuis la sortie de `JSONSerialization` (frappée `Any`).
    /// Les nombres sont conservés int quand ils sont entiers.
    public init(jsonObject value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // PAS de `as Bool` avant : tout NSNumber (y compris 0/1) s'y
            // convertirait. __NSCFBoolean a objCType "c" — c'est le seul bool.
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" {
                self = .bool(n.boolValue)
            } else if ["i", "s", "l", "q", "I", "S", "L", "Q"].contains(type) {
                self = .int(n.intValue)
            } else {
                self = .double(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(try a.map { try JSONValue(jsonObject: $0) })
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o { out[k] = try JSONValue(jsonObject: v) }
            self = .object(out)
        default:
            throw JSONConversionError.unsupportedType(String(describing: type(of: value)))
        }
    }

    /// Reconvertit vers `Any` pour `JSONSerialization`.
    public func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.toAny() }
        case .object(let o): return o.mapValues { $0.toAny() }
        }
    }

    public func encoded() throws -> Data {
        switch self {
        case .object, .array:
            return try JSONSerialization.data(withJSONObject: toAny(), options: [.sortedKeys])
        default:
            // JSONSerialization refuse les fragments top-level (String, nombre,
            // bool, null) en écriture — alors que ce sont du JSON valide
            // (RFC 8259) et que JSONSerialization les RELIT très bien.
            // On encode enveloppé puis on retire les crochets.
            let wrapped = try JSONSerialization.data(withJSONObject: [toAny()], options: [])
            guard wrapped.count >= 2 else {
                throw JSONConversionError.unsupportedType("fragment vide")
            }
            return wrapped.dropFirst().dropLast()
        }
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONValue(jsonObject: try JSONSerialization.jsonObject(with: data))
    }

    /// Aperçu compact pour les journaux et événements (jamais de dump entier).
    public func preview(maxChars: Int = 160) -> String {
        let raw = (try? String(data: encoded(), encoding: .utf8)) ?? "?"
        guard raw.count > maxChars else { return raw }
        return String(raw.prefix(maxChars)) + "…"
    }

    // MARK: - Codable naturel (pas de `{"_0": …}` synthétisé)
    //
    // Le Codable synthétisé des enums enveloppe chaque valeur associée sous
    // une clé `_0` (`{"object": {"_0": {…}}}`) : transcripts illisibles et
    // doublés de volume. Ici l'encodage est le JSON naturel.

    private static func decode(from decoder: Decoder) throws -> JSONValue {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { return .null }
        if let b = try? single.decode(Bool.self) { return .bool(b) }
        if let i = try? single.decode(Int.self) { return .int(i) }
        if let d = try? single.decode(Double.self) { return .double(d) }
        if let s = try? single.decode(String.self) { return .string(s) }
        if let a = try? single.decode([JSONValue].self) { return .array(a) }
        return .object(try single.decode([String: JSONValue].self))
    }

    public init(from decoder: Decoder) throws {
        self = try Self.decode(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let b): try single.encode(b)
        case .int(let i): try single.encode(i)
        case .double(let d): try single.encode(d)
        case .string(let s): try single.encode(s)
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }
}

public enum JSONConversionError: Error, Sendable, Equatable {
    case unsupportedType(String)
}
