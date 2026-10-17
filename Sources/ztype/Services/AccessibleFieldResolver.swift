import ApplicationServices
import Foundation

struct AccessibleFieldCapabilities {
    let role: String
    var editable: Bool?
    var valueSettable = false
    var hasSelection = false
    var hasTextRanges = false
    var hasInsertionLine = false

    var isEditor: Bool {
        guard editable != false else { return false }
        if [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) { return true }
        if editable == true, hasSelection, hasTextRanges,
           ![kAXStaticTextRole, kAXButtonRole, kAXWindowRole, kAXApplicationRole, kAXToolbarRole].contains(role) {
            return true
        }
        guard ["AXLayoutArea", "AXLayoutItem", kAXGroupRole].contains(role),
              hasSelection, hasTextRanges else { return false }
        return editable == true || valueSettable || hasInsertionLine
    }
}

struct AccessibleFieldResolver<Node> {
    enum Kind { case editor, container, secure, boundary, blocked }
    let equal: (Node, Node) -> Bool
    let kind: (Node) -> Kind
    let focused: (Node) -> Bool
    let hasSelection: (Node) -> Bool
    let parent: (Node) -> Node?
    let children: (Node) -> [Node]
    var withinBudget: () -> Bool = { true }
    var maximumNodes = 64
    var maximumDepth = 8

    func resolve(_ focus: Node) -> Node? {
        switch kind(focus) {
        case .editor, .secure: return focus
        case .boundary, .blocked: return nil
        case .container: break
        }

        // Resolve focused text leaves upwards before spending the subtree budget.
        var ancestor = focus
        var lineage = [focus]
        for _ in 0..<maximumDepth {
            guard withinBudget(), let next = parent(ancestor),
                  !lineage.contains(where: { equal($0, next) }) else { break }
            lineage.append(next)
            switch kind(next) {
            case .editor, .secure: return next
            case .boundary: break
            case .blocked: return nil
            case .container:
                ancestor = next
                continue
            }
            break
        }

        var queue: [(Node, Int)] = [(focus, 0)]
        var visited: [Node] = []
        var candidates: [Node] = []
        var truncated = false
        while !queue.isEmpty, visited.count < maximumNodes, withinBudget() {
            let (node, depth) = queue.removeFirst()
            guard !visited.contains(where: { equal($0, node) }) else { continue }
            visited.append(node)
            switch kind(node) {
            case .editor:
                if focused(node) { return node }
                if hasSelection(node) { candidates.append(node) }
            case .secure: return nil
            case .blocked, .boundary: continue
            case .container:
                let next = children(node)
                if depth < maximumDepth { queue.append(contentsOf: next.map { ($0, depth + 1) }) }
                else if !next.isEmpty { truncated = true }
            }
        }
        // A partially searched tree cannot establish that an editor is unique.
        guard queue.isEmpty, !truncated, candidates.count == 1 else { return nil }
        return candidates[0]
    }
}
