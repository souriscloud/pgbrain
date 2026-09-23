import XCTest

/// `XCTAssertThrowsError` doesn't await an async expression, so provide an
/// async-aware variant: fails if no error is thrown, otherwise hands the thrown
/// error to `errorHandler` for inspection.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error but none was thrown. \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

/// Tests that write to the real login Keychain are opt-in: every rebuild of
/// the test binary has a new ad-hoc signature, so macOS asks for the login
/// password on each run. Run them with `PGBRAIN_KEYCHAIN_TESTS=1 swift test`.
func requireKeychainTests(file: StaticString = #filePath, line: UInt = #line) throws {
    guard ProcessInfo.processInfo.environment["PGBRAIN_KEYCHAIN_TESTS"] == "1" else {
        throw XCTSkip("Keychain tests are opt-in (PGBRAIN_KEYCHAIN_TESTS=1)", file: file, line: line)
    }
}
