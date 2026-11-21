#if os(macOS)
import Foundation

struct PackError: LocalizedError, Sendable {
    var errorDescription: String? { message }
    let message: String

    init(_ message: String) { self.message = message }
}

struct OrderedObject: Sendable, ExpressibleByDictionaryLiteral {
    struct Field: Sendable {
        let key: String
        var value: JSONValue
    }

    private(set) var fields: [Field] = []

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    subscript(_ key: String) -> JSONValue? {
        get { fields.first { $0.key == key }?.value }
        set {
            if let index = fields.firstIndex(where: { $0.key == key }) {
                if let newValue { fields[index].value = newValue }
                else { fields.remove(at: index) }
            } else if let newValue {
                fields.append(Field(key: key, value: newValue))
            }
        }
    }

    func filtering(_ keep: (Field) throws -> Bool) rethrows -> Self {
        var result: Self = [:]
        result.fields = try fields.filter(keep)
        return result
    }

    mutating func forEachEntry(_ operation: (inout OrderedObject) throws -> Bool) rethrows {
        for field in fields {
            guard case var .object(row) = field.value else { continue }
            if field.key == "variants" || row["overlap"]?.object != nil {
                let variants = field.key == "variants"
                var entries = variants ? row : row["overlap"]!.object!
                for child in entries.fields {
                    guard case var .object(entry) = child.value else { continue }
                    entries[child.key] = try operation(&entry) ? .object(entry) : nil
                }
                if variants {
                    self[field.key] = .object(entries)
                } else if entries.fields.isEmpty {
                    self[field.key] = nil
                } else {
                    row["overlap"] = .object(entries)
                    self[field.key] = .object(row)
                }
            } else {
                self[field.key] = try operation(&row) ? .object(row) : nil
            }
        }
    }

    var entries: [OrderedObject] {
        fields.flatMap { field -> [OrderedObject] in
            guard let row = field.value.object else { return [] }
            if field.key == "variants" { return row.fields.compactMap { $0.value.object } }
            if let overlap = row["overlap"]?.object { return overlap.fields.compactMap { $0.value.object } }
            return [row]
        }
    }

    mutating func addVariant(_ name: String, entry: OrderedObject) throws {
        guard var variants = self["variants"]?.object else { throw PackError("Base must be an Apple Frames 4 pack") }
        guard variants[name] == nil else { throw PackError("Base already defines \(name)") }
        variants[name] = .object(entry)
        self["variants"] = .object(variants)
    }

    mutating func addWidth(_ width: Int, entry: OrderedObject, height: Int? = nil) throws {
        let key = String(width)
        guard self[key] == nil else { throw PackError("Base already defines width \(key)") }
        self[key] = height.map { .object(["overlap": .object([String($0): .object(entry)])]) } ?? .object(entry)
    }
}

indirect enum JSONValue: Sendable, ExpressibleByStringLiteral {
    case object(OrderedObject)
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    init(stringLiteral value: String) { self = .string(value) }

    var object: OrderedObject? { if case let .object(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var integer: Int? {
        switch self {
        case let .string(value), let .number(value): Int(value)
        default: nil
        }
    }

    static func double(_ value: Double) -> Self {
        // Swift and Python both use the shortest round-trippable decimal.
        let digits = String(value)
        if let scientific = digits.split(separator: "e").last, digits.contains("e"),
           let exponent = Int(scientific), (-4..<16).contains(exponent) {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 20
            if let fixed = formatter.string(from: NSNumber(value: value)) { return .number(fixed) }
        }
        return .number(digits)
    }

    static func document(_ bytes: Data) throws -> OrderedObject {
        var reader = JSONReader(bytes: Array(bytes))
        guard let object = try reader.value().object, reader.peek == nil else {
            throw PackError("NewFrames.json must contain a JSON object")
        }
        return object
    }

    func encoded(indent: Int = 2) -> Data { Data((format(depth: 0, indent: indent) + "\n").utf8) }

    private func format(depth: Int, indent: Int) -> String {
        let next = String(repeating: " ", count: (depth + 1) * indent)
        let current = String(repeating: " ", count: depth * indent)
        switch self {
        case let .object(object):
            guard !object.fields.isEmpty else { return "{}" }
            return "{\n" + object.fields.map { next + Self.quoted($0.key) + ": " + $0.value.format(depth: depth + 1, indent: indent) }
                .joined(separator: ",\n") + "\n" + current + "}"
        case let .array(values):
            guard !values.isEmpty else { return "[]" }
            return "[\n" + values.map { next + $0.format(depth: depth + 1, indent: indent) }
                .joined(separator: ",\n") + "\n" + current + "]"
        case let .string(value): return Self.quoted(value)
        case let .number(value): return value
        case let .bool(value): return value ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for unit in string.utf16 {
            switch unit {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 32...126: result.unicodeScalars.append(UnicodeScalar(unit)!)
            default: result += String(format: "\\u%04x", Int(unit))
            }
        }
        return result + "\""
    }
}

private struct JSONReader {
    let bytes: [UInt8]
    var index = 0

    var peek: UInt8? {
        mutating get {
            while index < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[index]) { index += 1 }
            return index < bytes.count ? bytes[index] : nil
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw invalid }
    }

    var invalid: PackError { PackError("NewFrames.json is not valid JSON (byte \(index))") }

    mutating func value(depth: Int = 0) throws -> JSONValue {
        guard depth < 128, let next = peek else { throw invalid }
        switch next {
        case 123:
            index += 1
            var object: OrderedObject = [:]
            if !consume(125) {
                repeat {
                    let key = try string()
                    guard object[key] == nil else { throw invalid }
                    try require(58)
                    object[key] = try value(depth: depth + 1)
                } while consume(44)
                try require(125)
            }
            return .object(object)
        case 91:
            index += 1
            var elements: [JSONValue] = []
            if !consume(93) {
                repeat { elements.append(try value(depth: depth + 1)) } while consume(44)
                try require(93)
            }
            return .array(elements)
        case 34: return .string(try string())
        case 116:
            try literal("true")
            return .bool(true)
        case 102:
            try literal("false")
            return .bool(false)
        case 110:
            try literal("null")
            return .null
        case 45, 48...57:
            let start = index
            while index < bytes.count, "-+0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            let number = String(decoding: bytes[start..<index], as: UTF8.self)
            guard number.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?/) != nil,
                  Double(number)?.isFinite == true else { throw invalid }
            return .number(number)
        default: throw invalid
        }
    }

    mutating func literal(_ token: String) throws {
        guard bytes[index...].starts(with: token.utf8) else { throw invalid }
        index += token.utf8.count
    }

    mutating func string() throws -> String {
        _ = peek
        let start = index
        try require(34)
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else {
                    throw invalid
                }
                return value
            }
            if byte == 92 {
                guard index < bytes.count else { throw invalid }
                index += 1
            }
        }
        throw invalid
    }
}
#endif
