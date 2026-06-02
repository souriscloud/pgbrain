import XCTest
@testable import pgBrain

final class PgDumpCLITests: XCTestCase {

    private func conn(db: String = "app") -> Connection {
        Connection(name: "c", host: "db.example.com", port: 6543, database: db, username: "alice")
    }

    func testFormatMetadata() {
        XCTAssertEqual(PgDumpCLI.Format.allCases.count, 4)
        XCTAssertEqual(PgDumpCLI.Format.plain.flag, "p")
        XCTAssertEqual(PgDumpCLI.Format.custom.flag, "c")
        XCTAssertEqual(PgDumpCLI.Format.directory.flag, "d")
        XCTAssertEqual(PgDumpCLI.Format.tar.flag, "t")
        XCTAssertEqual(PgDumpCLI.Format.plain.fileExtension, "sql")
        XCTAssertEqual(PgDumpCLI.Format.custom.fileExtension, "dump")
        XCTAssertEqual(PgDumpCLI.Format.directory.fileExtension, "")
        for f in PgDumpCLI.Format.allCases { XCTAssertEqual(f.id, f.rawValue) }
    }

    func testDumpArgumentsCarryConnectionFormatAndFile() {
        let args = PgDumpCLI.dumpArguments(connection: conn(), format: .custom,
                                           destinationPath: "/tmp/out.dump")
        XCTAssertEqual(args, [
            "--host", "db.example.com",
            "--port", "6543",
            "--username", "alice",
            "--no-password",
            "--format", "c",
            "--file", "/tmp/out.dump",
            "app",
        ])
        // Password is never on the command line.
        XCTAssertFalse(args.contains { $0.lowercased().contains("password") && $0 != "--no-password" })
    }

    func testDumpArgumentsOmitDatabaseWhenEmptyAndAppendExtras() {
        let args = PgDumpCLI.dumpArguments(connection: conn(db: ""), format: .plain,
                                           destinationPath: "/tmp/x.sql",
                                           extraArgs: ["--schema", "public"])
        XCTAssertFalse(args.contains("app"))
        XCTAssertEqual(args.suffix(2), ["--schema", "public"])
        XCTAssertEqual(args[args.firstIndex(of: "--format")! + 1], "p")
    }

    func testRestoreArgumentsBaseline() {
        let args = PgDumpCLI.restoreArguments(connection: conn(), dbname: "restored_db",
                                              archivePath: "/tmp/in.dump")
        XCTAssertEqual(args, [
            "--host", "db.example.com",
            "--port", "6543",
            "--username", "alice",
            "--no-password",
            "--dbname", "restored_db",
            "/tmp/in.dump",
        ])
    }

    func testRestoreArgumentsCleanNoOwnerAndParallel() {
        let opts = PgDumpCLI.RestoreOptions(clean: true, noOwner: true, jobs: 4)
        let args = PgDumpCLI.restoreArguments(connection: conn(), dbname: "d",
                                              archivePath: "/a.dump", options: opts)
        XCTAssertTrue(args.contains("--clean"))
        XCTAssertTrue(args.contains("--if-exists"))
        XCTAssertTrue(args.contains("--no-owner"))
        XCTAssertEqual(args[args.firstIndex(of: "--jobs")! + 1], "4")
        XCTAssertFalse(args.contains("--single-transaction"))
        XCTAssertEqual(args.last, "/a.dump", "archive path is positional, last")
    }

    func testRestoreSingleTransactionSuppressesParallelJobs() {
        // --jobs is incompatible with --single-transaction; the builder must
        // drop the parallel flag.
        let opts = PgDumpCLI.RestoreOptions(singleTransaction: true, jobs: 8)
        let args = PgDumpCLI.restoreArguments(connection: conn(), dbname: "d",
                                              archivePath: "/a.dump", options: opts)
        XCTAssertTrue(args.contains("--single-transaction"))
        XCTAssertFalse(args.contains("--jobs"))
    }

    func testLocateBinaryThrowsWhenAbsent() {
        // A name that won't exist anywhere on the search path.
        XCTAssertThrowsError(try PgDumpCLI.locateBinary(named: "pg_nope_xyz_123")) { error in
            guard case PgDumpCLI.CLIError.binaryNotFound = error else {
                return XCTFail("expected binaryNotFound, got \(error)")
            }
        }
    }
}
