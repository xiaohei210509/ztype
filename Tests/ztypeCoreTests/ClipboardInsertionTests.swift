import AppKit
import Testing
@testable import ztype

@MainActor
struct ClipboardInsertionTests {
    @Test func restoresEveryItemAndRepresentationAfterConfirmedPaste() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = NSPasteboardItem()
        first.setString("previous clipboard", forType: .string)
        first.setData(Data([1, 2, 3]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("file:///tmp/example.txt", forType: .fileURL)
        board.writeObjects([first, second])
        let lease = try #require(ClipboardInsertion(pasteboard: board))
        #expect(lease.stage("beautiful day."))
        #expect(board.string(forType: .string) == "beautiful day.")
        lease.finish(confirmed: true)
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.first?.string(forType: .string) == "previous clipboard")
        #expect(board.pasteboardItems?.first?.data(forType: .rtf) == Data([1, 2, 3]))
        #expect(board.pasteboardItems?.last?.string(forType: .fileURL) == "file:///tmp/example.txt")
    }

    @Test func aNewUserCopyIsNeverOverwrittenByRestoration() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let lease = try #require(ClipboardInsertion(pasteboard: board))
        #expect(lease.stage("candidate"))
        board.clearContents()
        board.setString("new user copy", forType: .string)
        lease.finish(confirmed: true)
        #expect(board.string(forType: .string) == "new user copy")
    }

    @Test func staleClipboardSnapshotCannotStartAPaste() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let lease = try #require(ClipboardInsertion(pasteboard: board))
        board.clearContents()
        board.setString("new", forType: .string)
        #expect(!lease.stage("candidate"))
        #expect(board.string(forType: .string) == "new")
    }

    @Test func oversizedClipboardIsLeftUntouched() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data(repeating: 7, count: 32), forType: .png)
        #expect(ClipboardInsertion(pasteboard: board, byteLimit: 16) == nil)
        #expect(board.data(forType: .png) == Data(repeating: 7, count: 32))
    }

    @Test func cancelledVerificationAllowsQueuedPasteToReadBeforeRestoration() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let lease = try #require(ClipboardInsertion(pasteboard: board))
        #expect(lease.stage("candidate"))
        lease.finish(confirmed: false)
        #expect(lease.isActive)
        try await Task.sleep(for: .milliseconds(50))
        #expect(board.string(forType: .string) == "candidate")
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.string(forType: .string) == "old")
        #expect(!lease.isActive)
    }
}
