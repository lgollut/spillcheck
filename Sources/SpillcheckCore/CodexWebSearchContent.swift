import Foundation

/// `WebSearchItem.results` is opaque JSON, not an MCP content-block list. Retain
/// original string leaves without decoding strings or interpreting business fields
/// such as `type`, `content`, `error`, or `status` as a second protocol.
struct CodexWebSearchContent {
    let maximumTextBytes: Int
    let maximumPointerBytes: Int
    private(set) var segments: [SourceSegment] = []
    private(set) var budgetExceeded = false
    private var nodes = 0
    private var textBytes = 0
    private var pointerBytes = 0
    private var pointerBudgetExhausted = false

    init(maximumTextBytes: Int, maximumPointerBytes: Int = 1024 * 1024) {
        self.maximumTextBytes = maximumTextBytes
        self.maximumPointerBytes = maximumPointerBytes
    }

    mutating func collect(_ value: CodexJSON, pointer: String = "/results", depth: Int = 0) throws {
        guard !pointerBudgetExhausted else { return }
        guard admitPointer(bytes: pointer.utf8.count) else { return }
        guard depth <= 32, nodes < 8192, segments.count < 1024 else {
            budgetExceeded = true; return
        }
        nodes += 1
        if nodes % 64 == 0 { try Task.checkCancellation() }
        switch value {
        case .string(let text):
            guard !text.isEmpty else { return }
            let bytes = Data(text.utf8)
            guard bytes.count <= maximumTextBytes - textBytes else {
                budgetExceeded = true; return
            }
            textBytes += bytes.count
            segments.append(try .init(id: pointer, utf8: bytes))
        case .array(let values):
            for (index, child) in values.enumerated() {
                guard nodes < 8192, segments.count < 1024 else { budgetExceeded = true; break }
                let component = String(index)
                guard canConstructPointer(parentBytes: pointer.utf8.count, componentBytes: component.utf8.count) else { break }
                try collect(child, pointer: pointer + "/" + component, depth: depth + 1)
            }
        case .object(let values):
            for key in values.keys.sorted() {
                guard nodes < 8192, segments.count < 1024 else { budgetExceeded = true; break }
                guard !pointerBudgetExhausted else { break }
                let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                guard canConstructPointer(parentBytes: pointer.utf8.count, componentBytes: escaped.utf8.count) else { break }
                try collect(values[key]!, pointer: pointer + "/" + escaped, depth: depth + 1)
            }
        case .number, .bool, .null: break
        }
    }

    /// Count every visited path, including paths that contain no string leaves.
    /// Repeated array children must not copy a large common key after capacity is
    /// exhausted. Exhaustion is terminal so skipped nodes cannot repeat that work.
    private mutating func canConstructPointer(parentBytes: Int, componentBytes: Int) -> Bool {
        guard !pointerBudgetExhausted else { return false }
        let remaining = maximumPointerBytes - pointerBytes
        guard parentBytes < remaining, componentBytes <= remaining - parentBytes - 1 else {
            budgetExceeded = true; pointerBudgetExhausted = true; return false
        }
        return true
    }

    private mutating func admitPointer(bytes: Int) -> Bool {
        guard bytes <= maximumPointerBytes - pointerBytes else {
            budgetExceeded = true; pointerBudgetExhausted = true; return false
        }
        pointerBytes += bytes
        return true
    }
}
