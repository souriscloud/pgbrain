import AppKit
import XCTest
@testable import pgBrain

@MainActor
final class F1_WindowManagerTests: XCTestCase {
    private func window() -> NSWindow {
        NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    }

    private func connection(database: String) -> Connection {
        var c = Connection(name: "wm")
        c.username = "alice"
        c.database = database
        return c
    }

    func testResolveRules() {
        XCTAssertEqual(WindowManager.resolve(database: "sales", reported: "x", username: "alice"), "sales")
        XCTAssertEqual(WindowManager.resolve(database: "", reported: "main", username: "alice"), "main")
        XCTAssertEqual(WindowManager.resolve(database: "", reported: "", username: "alice"), "alice")
    }

    func testDefaultDatabaseWindowMatchesItsResolvedName() {
        let manager = WindowManager()
        let base = connection(database: "")
        let service = ConnectionService(connection: base)
        let w = window()
        manager.register(window: w, service: service)

        XCTAssertTrue(manager.window(for: base.id, database: "", username: "alice") === w)
        XCTAssertTrue(manager.window(for: base.id, database: "alice", username: "alice") === w,
                      "picking the current (default) database must focus, not duplicate")
        XCTAssertNil(manager.window(for: base.id, database: "other", username: "alice"))
        XCTAssertEqual(manager.openDatabases(for: base.id), ["alice"])

        service.injectSchemaForTests(SchemaSnapshot(databaseName: "main", schemas: []))
        XCTAssertTrue(manager.window(for: base.id, database: "main", username: "alice") === w,
                      "server-reported name wins once known")
    }

    func testServiceLookupIsPerDatabase() {
        let manager = WindowManager()
        var onA = connection(database: "a")
        let serviceA = ConnectionService(connection: onA)
        manager.register(window: window(), service: serviceA)
        onA.database = "b"
        let serviceB = ConnectionService(connection: onA)
        manager.register(window: window(), service: serviceB)

        XCTAssertTrue(manager.service(for: onA.id, database: "b", username: "alice") === serviceB)
        XCTAssertTrue(manager.service(for: onA.id, database: "a", username: "alice") === serviceA)
        XCTAssertNil(manager.service(for: onA.id, database: "c", username: "alice"),
                     "a sibling window on another database must not stand in for the target")
        XCTAssertTrue(manager.hasWindow(for: onA.id))
    }

    func testExplicitDefaultNameMatchesEmptyRequest() {
        let manager = WindowManager()
        let named = connection(database: "alice")
        let w = window()
        manager.register(window: w, service: ConnectionService(connection: named))
        XCTAssertTrue(manager.window(for: named.id, database: "", username: "alice") === w,
                      "restoring a window saved on \"\" merges into the one already on the default db")
    }
}
