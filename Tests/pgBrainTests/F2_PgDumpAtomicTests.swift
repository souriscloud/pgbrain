import XCTest
@testable import pgBrain

/// pg_dump writes to a private temp sibling and only replaces the destination
/// on success — a failed run must never destroy a previous good dump.
final class F2_PgDumpAtomicTests: XCTestCase {
    private var dir: URL!
    private let conn = Connection(name: "c", host: "h", database: "d", username: "u")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-f2dump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ name: String, body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func dump(_ tool: URL, to out: URL, format: PgDumpCLI.Format = .custom) async throws -> PgDumpCLI.Result {
        try await PgDumpCLI.dumpAtomically(
            binary: tool, connection: conn, password: "", format: format,
            destination: out, extraArgs: [], tunnelPort: nil, started: Date())
    }

    private func siblings() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".pgbrain-") }
    }

    func testFailureKeepsPreviousDump() async throws {
        let out = dir.appendingPathComponent("prod.dump")
        try Data("previous good dump".utf8).write(to: out)
        let tool = try script("pg_fail", body: """
        for a in "$@"; do case "$a" in --file=*) echo partial > "${a#--file=}";; esac; done
        exit 1
        """)
        do {
            _ = try await dump(tool, to: out)
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "previous good dump")
        XCTAssertEqual(try siblings(), [], "temp removed")
    }

    func testSuccessReplacesAndTempIsPrivateWhileWriting() async throws {
        let out = dir.appendingPathComponent("prod.dump")
        try Data("old".utf8).write(to: out)
        let seen = dir.appendingPathComponent("mode.txt").path
        let tool = try script("pg_ok", body: """
        for a in "$@"; do case "$a" in --file=*)
            f="${a#--file=}"
            stat -f %Lp "$f" > "\(seen)"
            echo "$f" >> "\(seen)"
            echo fresh > "$f";;
        esac; done
        """)
        let result = try await dump(tool, to: out)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "fresh\n")
        let lines = try String(contentsOfFile: seen, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.first, "600")
        XCTAssertNotEqual(lines.dropFirst().first.map(String.init), out.path, "wrote to a temp sibling")
        XCTAssertEqual(URL(fileURLWithPath: String(lines[1])).deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL)
        XCTAssertEqual(try siblings(), [])
    }

    func testDirectoryFormatReplacesExistingDirectory() async throws {
        let out = dir.appendingPathComponent("dumpdir")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: out.appendingPathComponent("toc.dat"))
        let tool = try script("pg_dir", body: """
        for a in "$@"; do case "$a" in --file=*)
            f="${a#--file=}"
            [ -e "$f" ] && exit 3
            mkdir "$f" && echo new > "$f/toc.dat";;
        esac; done
        """)
        _ = try await dump(tool, to: out, format: .directory)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("toc.dat"), encoding: .utf8), "new\n")
        XCTAssertEqual(try siblings(), [])

        let failing = try script("pg_dir_fail", body: """
        for a in "$@"; do case "$a" in --file=*) mkdir "${a#--file=}";; esac; done
        exit 1
        """)
        do {
            _ = try await dump(failing, to: out, format: .directory)
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("toc.dat"), encoding: .utf8), "new\n")
        XCTAssertEqual(try siblings(), [])
    }
}
