import ApplicationServices

struct AccessibilityNotificationLedger<Element> {
    enum Outcome: Equatable {
        case registered, unsupported, retry
    }

    private struct Entry {
        let element: Element
        let name: String
        let outcome: Outcome
    }

    private var entries: [Entry] = []
    let equal: (Element, Element) -> Bool

    init(equal: @escaping (Element, Element) -> Bool) {
        self.equal = equal
    }

    mutating func register(_ name: String, on element: Element,
                           add: () -> AXError) -> Outcome {
        if let existing = entries.first(where: { $0.name == name && equal($0.element, element) }) {
            return existing.outcome
        }
        let outcome: Outcome
        switch add() {
        case .success, .notificationAlreadyRegistered: outcome = .registered
        case .notificationUnsupported, .notImplemented: outcome = .unsupported
        default: outcome = .retry
        }
        if outcome != .retry { entries.append(Entry(element: element, name: name, outcome: outcome)) }
        return outcome
    }

    mutating func remove(from element: Element? = nil, remove: (Element, String) -> Void) {
        let equal = self.equal
        entries.removeAll { entry in
            guard element.map({ equal(entry.element, $0) }) ?? true else { return false }
            if entry.outcome == .registered { remove(entry.element, entry.name) }
            return true
        }
    }
}

@MainActor
final class AccessibilityObservationRecovery {
    private let delays: [Duration]
    private var task: Task<Void, Never>?
    private var epoch = 0

    init(delays: [Duration] = [.milliseconds(80), .milliseconds(240), .milliseconds(600)]) {
        self.delays = delays
    }

    func request(isCurrent: @escaping () -> Bool, repair: @escaping () -> Bool) {
        guard task == nil else { return }
        epoch += 1
        let currentEpoch = epoch
        task = Task { @MainActor [weak self, delays] in
            defer {
                if self?.epoch == currentEpoch { self?.task = nil }
            }
            for delay in delays {
                do { try await Task.sleep(for: delay) } catch { return }
                guard !Task.isCancelled, isCurrent() else { return }
                if repair() { return }
            }
        }
    }

    func cancel() {
        epoch += 1
        task?.cancel()
        task = nil
    }
}
