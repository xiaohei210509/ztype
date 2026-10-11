import AppKit

@MainActor
final class ClipboardInsertion {
    private let pasteboard: NSPasteboard
    private let savedItems: [NSPasteboardItem]
    private let originalChangeCount: Int
    private var ownedChangeCount: Int?
    private var recoveryTask: Task<Void, Never>?
    var isActive: Bool { ownedChangeCount != nil }

    init?(pasteboard: NSPasteboard, byteLimit: Int = 8_388_608) {
        self.pasteboard = pasteboard
        originalChangeCount = pasteboard.changeCount
        guard byteLimit >= 0 else { return nil }
        let items = pasteboard.pasteboardItems ?? []
        guard !items.isEmpty || (pasteboard.types ?? []).isEmpty else { return nil }
        guard items.count <= 32 else { return nil }
        var copies: [NSPasteboardItem] = []
        var bytes = 0
        for item in items {
            guard item.types.count <= 32 else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    // AppKit advertises this derived representation even when no bytes exist.
                    if type.rawValue == "public.utf16-external-plain-text",
                       item.data(forType: .string) != nil { continue }
                    return nil
                }
                guard data.count <= byteLimit - bytes,
                      copy.setData(data, forType: type) else { return nil }
                bytes += data.count
            }
            copies.append(copy)
        }
        guard pasteboard.changeCount == originalChangeCount else { return nil }
        savedItems = copies
    }

    func stage(_ text: String) -> Bool {
        guard ownedChangeCount == nil, pasteboard.changeCount == originalChangeCount else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        ownedChangeCount = pasteboard.changeCount
        let written = pasteboard.writeObjects([item])
        ownedChangeCount = pasteboard.changeCount
        guard written else { restore(); return false }
        // Recovery is bounded even if the editor never acknowledges the paste.
        recoveryTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            self.restore()
        }
        return true
    }

    func finish(confirmed: Bool) {
        if confirmed {
            restore()
        } else {
            // A posted paste may still be queued when input cancels verification.
            recoveryTask?.cancel()
            recoveryTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self.restore()
            }
        }
    }

    func restore() {
        recoveryTask?.cancel()
        recoveryTask = nil
        guard let ownedChangeCount else { return }
        self.ownedChangeCount = nil
        // Never overwrite something the user copied while we held the pasteboard.
        guard pasteboard.changeCount == ownedChangeCount else { return }
        pasteboard.clearContents()
        if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
    }
}
