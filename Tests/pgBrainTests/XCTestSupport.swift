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
