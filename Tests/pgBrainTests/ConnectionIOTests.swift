import XCTest
import AppKit
@testable import pgBrain

@MainActor
final class ConnectionIOTests: XCTestCase {

    // The system pasteboard isn't always reachable (e.g. a windowserver-less
    // CI box); probe once and skip the round-trip tests when it isn't.
    private func pasteboardWorks() -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("pgbrain_probe", forType: .string)
        return pb.string(forType: .string) == "pgbrain_probe"
    }

    func testImportResultCases() {
        // Smoke the enum so its cases are referenced.
        let results: [ConnectionIO.ImportResult] = [.imported(3), .cancelled, .unrecognised]
        if case .imported(let n) = results[0] { XCTAssertEqual(n, 3) } else { XCTFail() }
    }

    func testCopyToClipboardRendersParseableBundle() throws {
        try XCTSkipUnless(pasteboardWorks(), "no usable pasteboard here")
        let conns = [
            Connection(name: "Alpha", host: "h1", port: 5432, database: "d1", username: "u1"),
            Connection(name: "Beta", host: "h2", port: 6000, database: "d2", username: "u2"),
        ]
        ConnectionIO.copyToClipboard(conns, includePasswords: false)
        let text = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        let parsed = try XCTUnwrap(ConnectionExchange.parseBundle(text))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.map { $0.connection.name }.sorted(), ["Alpha", "Beta"])
    }

    func testImportFromClipboardEmptyIsCancelled() throws {
        try XCTSkipUnless(pasteboardWorks(), "no usable pasteboard here")
        NSPasteboard.general.clearContents()  // empty → .cancelled
        guard case .cancelled = ConnectionIO.importFromClipboard() else {
            return XCTFail("empty clipboard should cancel")
        }
    }

    func testImportFromClipboardGarbageIsUnrecognised() throws {
        try XCTSkipUnless(pasteboardWorks(), "no usable pasteboard here")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("this is not a pgBrain bundle", forType: .string)
        guard case .unrecognised = ConnectionIO.importFromClipboard() else {
            return XCTFail("non-bundle text should be unrecognised")
        }
    }
}
