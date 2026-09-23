import XCTest
@testable import pgBrain

final class D_PgDumpCLITests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-pgdump-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Drop an executable shell script at `<dir>/<sub>/<name>`.
    @discardableResult
    private func script(_ name: String, in sub: String, body: String) throws -> URL {
        let folder = dir.appendingPathComponent(sub)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func fakeVersion(_ version: String, in sub: String, name: String = "pg_fakedump") throws {
        try script(name, in: sub, body: "echo \"\(name) (PostgreSQL) \(version)\"")
    }

    // MARK: Version selection

    func testParseMajorVersion() {
        XCTAssertEqual(PgDumpCLI.parseMajorVersion("pg_dump (PostgreSQL) 18.0"), 18)
        XCTAssertEqual(PgDumpCLI.parseMajorVersion("pg_dump (PostgreSQL) 17.2 (Homebrew)"), 17)
        XCTAssertEqual(PgDumpCLI.parseMajorVersion("pg_dump (PostgreSQL) 9.6.24"), 9)
        XCTAssertNil(PgDumpCLI.parseMajorVersion("garbage"))
        XCTAssertEqual(PgDumpCLI.majorVersion(fromServerVersionNum: 180_001), 18)
        XCTAssertEqual(PgDumpCLI.majorVersion(fromServerVersionNum: 90_624), 9)
    }

    func testSelectPrefersHighestAndEnforcesServerMajor() throws {
        let cands = [
            PgDumpCLI.Candidate(path: "/a/16", major: 16),
            PgDumpCLI.Candidate(path: "/b/18", major: 18),
            PgDumpCLI.Candidate(path: "/c/18", major: 18),
            PgDumpCLI.Candidate(path: "/d/unknown", major: nil),
        ]
        XCTAssertEqual(try PgDumpCLI.select(cands, serverMajor: nil, name: "pg_dump").path, "/b/18",
                       "first of the equal-highest wins")
        XCTAssertEqual(try PgDumpCLI.select(cands, serverMajor: 17, name: "pg_dump").path, "/b/18")
        XCTAssertThrowsError(try PgDumpCLI.select(Array(cands.prefix(1)), serverMajor: 17, name: "pg_dump")) { error in
            guard case PgDumpCLI.CLIError.binaryTooOld(_, 17, let found) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, ["/a/16 (16)"])
        }
    }

    func testFindBinaryProbesFakeInstalls() async throws {
        try fakeVersion("16.4", in: "pg16")
        try fakeVersion("18.0", in: "pg18")
        try fakeVersion("17.2", in: "pg17")
        let dirs = ["pg16", "pg18", "pg17", "missing"].map { dir.appendingPathComponent($0).path }

        let best = try await PgDumpCLI.findBinary(named: "pg_fakedump", serverVersionNum: 170_002, searchDirectories: dirs)
        XCTAssertEqual(best.deletingLastPathComponent().lastPathComponent, "pg18")

        let tooNew = dirs.filter { !$0.hasSuffix("pg18") }
        await XCTAssertThrowsErrorAsync(
            try await PgDumpCLI.findBinary(named: "pg_fakedump", serverVersionNum: 180_000, searchDirectories: tooNew)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("PostgreSQL 18"), error.localizedDescription)
        }
        await XCTAssertThrowsErrorAsync(
            try await PgDumpCLI.findBinary(named: "pg_nothing_here", searchDirectories: dirs)
        ) { error in
            guard case PgDumpCLI.CLIError.binaryNotFound = error else { return XCTFail("\(error)") }
        }
    }

    func testSearchPatternsIncludePostgres18Locations() {
        XCTAssertTrue(PgDumpCLI.searchPatterns.contains("/Applications/Postgres.app/Contents/Versions/*/bin"))
        XCTAssertTrue(PgDumpCLI.searchPatterns.contains("/opt/homebrew/opt/postgresql@*/bin"))
        XCTAssertTrue(PgDumpCLI.searchPatterns.contains("/Library/PostgreSQL/*/bin"))
    }

    func testGlobExpansionOrdersNewestFirst() throws {
        for v in ["15", "18", "9.6"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("postgresql@\(v)/bin"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("unrelated/bin"), withIntermediateDirectories: true)
        let expanded = PgDumpCLI.expandedSearchDirectories([dir.path + "/postgresql@*/bin"])
        XCTAssertEqual(expanded.map { ($0 as NSString).deletingLastPathComponent.components(separatedBy: "@").last! },
                       ["18", "15", "9.6"])
    }

    // MARK: Injection-safe arguments + environment

    func testDatabaseNameCannotInjectOptions() {
        let c = Connection(name: "c", host: "h", port: 5432, database: "-f/etc/passwd x='y'", username: "u")
        let args = PgDumpCLI.dumpArguments(connection: c, format: .plain, destinationPath: "/tmp/o.sql")
        XCTAssertEqual(args.last, #"--dbname=dbname='-f/etc/passwd x=\'y\''"#)
        XCTAssertEqual(PgDumpCLI.conninfoQuote(#"a\b'c"#), #"'a\\b\'c'"#)
        let restore = PgDumpCLI.restoreArguments(connection: c, dbname: "a=b", archivePath: "-archive")
        XCTAssertTrue(restore.contains("--dbname=dbname='a=b'"))
        XCTAssertEqual(restore.suffix(2), ["--", "-archive"])
    }

    func testEnvironmentStripsPGVarsAndCarriesTLSAndTunnel() {
        let c = Connection(name: "c", host: "db.example.com", sslMode: .verifyFull,
                           sslRootCertPath: "~/ca.pem", sslClientCertPath: "/c.pem", sslClientKeyPath: "/k.pem")
        let env = PgDumpCLI.environment(for: c, tunnelPort: 40001, passfile: "/tmp/pass",
                                        base: ["PATH": "/bin", "PGPASSWORD": "leak", "PGHOST": "evil", "PGSERVICE": "x"])
        XCTAssertEqual(env["PATH"], "/bin")
        XCTAssertNil(env["PGPASSWORD"])
        XCTAssertNil(env["PGHOST"])
        XCTAssertNil(env["PGSERVICE"])
        XCTAssertEqual(env["PGSSLMODE"], "verify-full")
        XCTAssertFalse(env["PGSSLROOTCERT"]!.hasPrefix("~"))
        XCTAssertEqual(env["PGSSLCERT"], "/c.pem")
        XCTAssertEqual(env["PGSSLKEY"], "/k.pem")
        XCTAssertEqual(env["PGHOSTADDR"], "127.0.0.1")
        XCTAssertEqual(env["PGPORT"], "40001")
        XCTAssertEqual(env["PGPASSFILE"], "/tmp/pass")

        let direct = PgDumpCLI.environment(for: Connection(name: "d"), tunnelPort: nil, passfile: nil, base: [:])
        XCTAssertNil(direct["PGHOSTADDR"])
        XCTAssertNil(direct["PGPASSFILE"])
    }

    func testPgpassLineEscapes() {
        XCTAssertEqual(PgDumpCLI.pgpassLine(password: #"a:b\c"#), #"*:*:*:*:a\:b\\c"# + "\n")
    }

    // MARK: Running

    func testRunToolUsesPrivatePassfileAndCleansUp() async throws {
        let seen = dir.appendingPathComponent("seen.txt").path
        let tool = try script("pg_fake", in: "bin", body: """
        stat -f %Lp "$PGPASSFILE" > "\(seen)"
        cat "$PGPASSFILE" >> "\(seen)"
        echo "$PGPASSWORD" >> "\(seen)"
        for a in "$@"; do case "$a" in --file=*) echo dumped > "${a#--file=}";; esac; done
        echo "warning: fine" >&2
        """)
        let out = dir.appendingPathComponent("out.sql")
        let c = Connection(name: "c", host: "h", database: "d", username: "u")
        let result = try await PgDumpCLI.runTool(
            binary: tool, args: PgDumpCLI.dumpArguments(connection: c, format: .plain, destinationPath: out.path),
            connection: c, password: "pa:ss", tunnelPort: nil, output: out, started: Date())
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "warning: fine")
        XCTAssertEqual(result.bytesWritten, 7)
        let lines = try String(contentsOfFile: seen, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "600")
        XCTAssertEqual(lines[1], #"*:*:*:*:pa\:ss"#)
        XCTAssertEqual(lines[2], "", "PGPASSWORD is never set")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("pgbrain-") && $0.hasSuffix(".pgpass") }
        XCTAssertTrue(leftovers.isEmpty, "passfile deleted: \(leftovers)")
    }

    func testFailedRunDeletesPartialOutputButKeepsUntouchedFile() async throws {
        let tool = try script("pg_fail", in: "bin", body: """
        for a in "$@"; do case "$a" in --file=*) echo partial > "${a#--file=}";; esac; done
        echo "pg_dump: error: connection failed" >&2
        exit 1
        """)
        let out = dir.appendingPathComponent("partial.dump")
        let c = Connection(name: "c", host: "h", database: "d", username: "u")
        await XCTAssertThrowsErrorAsync(try await PgDumpCLI.runTool(
            binary: tool, args: PgDumpCLI.dumpArguments(connection: c, format: .custom, destinationPath: out.path),
            connection: c, password: "", tunnelPort: nil, output: out, started: Date())
        ) { error in
            guard case PgDumpCLI.CLIError.nonZeroExit(1, let stderr) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(stderr.contains("connection failed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "partial output removed")

        let untouched = dir.appendingPathComponent("keep.dump")
        try Data("precious".utf8).write(to: untouched)
        let noWrite = try script("pg_fail_early", in: "bin", body: "exit 2")
        await XCTAssertThrowsErrorAsync(try await PgDumpCLI.runTool(
            binary: noWrite, args: [], connection: c, password: "", tunnelPort: nil, output: untouched, started: Date()))
        XCTAssertEqual(try String(contentsOf: untouched, encoding: .utf8), "precious")
    }

    func testCancellationTerminatesTheProcess() async throws {
        let marker = dir.appendingPathComponent("alive").path
        let tool = try script("pg_slow", in: "bin", body: "sleep 30; touch \"\(marker)\"")
        let started = Date()
        let task = Task {
            try await PgDumpCLI.run(executable: tool, arguments: [], environment: [:], timeoutSeconds: nil)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let tool = try script("pg_chatty", in: "bin", body: "i=0; while [ $i -lt 4000 ]; do echo \"line $i of noisy stderr output\" >&2; i=$((i+1)); done")
        let out = try await PgDumpCLI.run(executable: tool, arguments: [], environment: [:], timeoutSeconds: 20)
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(out.stderr.contains("line 3999"))
    }
}
