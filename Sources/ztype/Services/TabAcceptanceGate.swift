import CoreGraphics

struct TabAcceptanceGate {
    private var claimed = false
    var isClaimed: Bool { claimed }

    mutating func reset() { claimed = false }

    mutating func consume(type: CGEventType, key: Int64, modifiers: CGEventFlags,
                          repeating: Bool, accept: () -> Bool) -> Bool {
        guard key == 48 else { return false }
        if type == .keyUp {
            let consume = claimed
            claimed = false
            return consume
        }
        guard type == .keyDown else { return false }
        if claimed { return true }
        guard !repeating, modifiers.isEmpty || modifiers == .maskAlternate, accept() else { return false }
        claimed = true
        return true
    }
}
