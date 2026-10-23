// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/variables/types.py,
// segments.py, factory.py (build_segment), segment_group.py. See ../NOTICE.md.

/// graphon's `SegmentType` (the runtime type of a variable value).
public enum SegmentType: String, Sendable, Hashable, Codable, CaseIterable {
    case number
    case integer
    case float
    case string
    case object
    case secret
    case file
    case boolean
    case arrayAny = "array[any]"
    case arrayString = "array[string]"
    case arrayNumber = "array[number]"
    case arrayObject = "array[object]"
    case arrayFile = "array[file]"
    case arrayBoolean = "array[boolean]"
    case none
    case group

    public var isArray: Bool {
        switch self {
        case .arrayAny, .arrayString, .arrayNumber, .arrayObject, .arrayFile, .arrayBoolean: return true
        default: return false
        }
    }

    /// `exposed_type()`: the frontend treats integers and floats as `number`.
    public var exposed: SegmentType { self == .integer || self == .float ? .number : self }
}

/// A runtime value with its type (graphon's `Segment` subclasses). File values carry opaque record identities,
/// materialized by a scoped adapter; their durable representation remains plain JSON.
public struct Segment: Hashable, Sendable, Codable {
    public var valueType: SegmentType
    public var value: JSONValue

    public init(_ valueType: SegmentType, _ value: JSONValue) {
        self.valueType = valueType
        self.value = value
    }

    public static let none = Segment(.none, .null)

    /// `build_segment(value)`: the type inferred from a Python value.
    public static func build(_ v: JSONValue) -> Segment {
        switch v {
        case .null: return Segment(.none, .null)
        case .string: return Segment(.string, v)
        case .bool: return Segment(.boolean, v)
        case .int: return Segment(.integer, v)
        case .double: return Segment(.float, v)
        case .object: return Segment(RuntimeFile.isFile(v) ? .file : .object, v)
        case .array(let items):
            let built = items.map(build)
            // `all(isinstance(item, ArraySegment))` is also true for an empty list.
            if built.allSatisfy({ $0.valueType.isArray }) { return Segment(.arrayAny, v) }
            let types = Set(built.map(\.valueType))
            if types.count != 1 {
                return types.isSubset(of: [.number, .integer, .float]) ? Segment(.arrayNumber, v) : Segment(.arrayAny, v)
            }
            switch types.first! {
            case .string: return Segment(.arrayString, v)
            case .number, .integer, .float: return Segment(.arrayNumber, v)
            case .boolean: return Segment(.arrayBoolean, v)
            case .object: return Segment(.arrayObject, v)
            case .file: return Segment(.arrayFile, v)
            default: return Segment(.arrayAny, v)
            }
        }
    }

    /// `segment.text`.
    public var text: String {
        switch valueType {
        case .none, .file, .arrayFile: return ""
        case .object: return value.pythonJSONDumps()
        case .arrayString:
            if case .array(let a) = value, a.isEmpty { return "" }
            return value.pythonJSONDumps()
        case .arrayAny, .arrayNumber, .arrayObject, .arrayBoolean:
            if case .array(let a) = value, a.isEmpty { return "" }
            return PythonText.str(value)
        default: return PythonText.str(value)
        }
    }

    /// `segment.log`.
    public var log: String {
        switch valueType {
        case .none, .file, .arrayFile: return ""
        case .object: return value.pythonJSONDumps(indent: 2)
        default: return PythonText.str(value)
        }
    }

    /// `segment.markdown`.
    public var markdown: String {
        switch valueType {
        case .none: return ""
        case .file: return RuntimeFile.markdown(value)
        case .arrayFile: return (value.array ?? []).map(RuntimeFile.markdown).joined(separator: "\n")
        case .object: return value.pythonJSONDumps(indent: 2)
        case .arrayAny, .arrayString, .arrayNumber, .arrayObject, .arrayBoolean:
            return (value.array ?? []).map { "- " + PythonText.str($0) }.joined(separator: "\n")
        default: return PythonText.str(value)
        }
    }

    /// `segment.to_object()`.
    public var object: JSONValue { value }
}

/// graphon's `SegmentGroup`: the parts of a rendered template.
public struct SegmentGroup: Sendable {
    public var value: [Segment]
    public init(_ value: [Segment]) { self.value = value }
    public var text: String { value.map(\.text).joined() }
    public var log: String { value.map(\.log).joined() }
    public var markdown: String { value.map(\.markdown).joined() }
}
