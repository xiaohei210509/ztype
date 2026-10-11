import Foundation

@MainActor
struct TextSubmission {
    let finish: (Bool) -> Void
    init(finish: @escaping (Bool) -> Void = { _ in }) { self.finish = finish }
}

enum TextInsertion {
    enum Confirmation {
        case unchanged, confirmed, diverged
    }

    static func confirm(before: String, after: String, location: Int, text: String,
                        currentBefore: String, currentAfter: String, currentLocation: Int,
                        currentSelectionLength: Int, contextLimit: Int = 1800) -> Confirmation {
        guard currentSelectionLength == 0 else { return .diverged }
        if currentLocation == location, currentBefore == before, currentAfter == after { return .unchanged }
        let length = (text as NSString).length
        guard location <= Int.max - length else { return .diverged }
        let expected = (before + text) as NSString
        let suffix = expected.substring(from: max(0, expected.length - contextLimit))
        return currentLocation == location + length && currentBefore == suffix && currentAfter == after ?
            .confirmed : .diverged
    }
}
