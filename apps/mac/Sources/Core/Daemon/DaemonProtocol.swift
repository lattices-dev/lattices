import Foundation

// MARK: - Wire Format

struct DaemonRequest: Codable {
    let id: String
    let method: String
    let params: JSON?
    /// Absolute Unix time in milliseconds, shared with the desktop client and Linux host.
    let deadline: Double?

    init(id: String, method: String, params: JSON?, deadline: Double? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.deadline = deadline
    }

    var isExpired: Bool { deadline.map { Date().timeIntervalSince1970 * 1000 >= $0 } ?? false }
}

struct DaemonResponse: Codable {
    let id: String
    let result: JSON?
    let error: String?
    /// On every reply to a `.mutate` endpoint: how far it got (DaemonDelivery).
    var delivery: JSON? = nil
}

struct DaemonEvent: Codable {
    let event: String
    let data: JSON
}

// MARK: - Dynamic JSON

enum JSON: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSON])
    case object([String: JSON])
    case null

    // MARK: Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSON].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSON].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i):    try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b):   try container.encode(b)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null:          try container.encodeNil()
        }
    }

    // MARK: Subscript helpers

    subscript(key: String) -> JSON? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    subscript(index: Int) -> JSON? {
        guard case .array(let arr) = self, index >= 0, index < arr.count else { return nil }
        return arr[index]
    }

    var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    var intValue: Int? {
        guard case .int(let i) = self else { return nil }
        return i
    }

    var uint32Value: UInt32? {
        guard case .int(let i) = self else { return nil }
        return UInt32(i)
    }

    var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    var arrayValue: [JSON]? {
        guard case .array(let a) = self else { return nil }
        return a
    }

    var numericDouble: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}
