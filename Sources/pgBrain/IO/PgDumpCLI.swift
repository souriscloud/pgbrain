import Foundation

/// Wrapper around the `pg_dump` / `pg_restore` command-line tools. Discovers
/// binaries from common install locations on macOS (Postgres.app, Homebrew,
/// EnterpriseDB, /usr/bin), picks the newest one that can talk to the server,
/// and lets Settings override the path.
///
/// Security posture of each run:
///   - the password goes into a temporary 0600 `PGPASSFILE`, never argv or env
///   - the database name travels as a quoted conninfo (`--dbname=dbname='…'`)
///     so a name starting with `-` or containing `=` can't inject options
///   - inherited `PG*` environment variables are dropped so the user's shell
///     setup can't silently redirect the dump
///   - SSH connections go through the tunnel's local port (`PGHOSTADDR`),
///     while `--host` keeps the real name for verify-full
enum PgDumpCLI {
    /// Filter for output formats supported by `pg_dump`. `plain` is the SQL
    /// text dump; `custom` is the binary `pg_restore`-able archive (which is
    /// what we'd actually recommend in production).
    enum Format: String, CaseIterable, Identifiable {
        case plain, custom, directory, tar
        var id: String { rawValue }
        var flag: String {
            switch self {
            case .plain: return "p"
            case .custom: return "c"
            case .directory: return "d"
            case .tar: return "t"
            }
        }
        var fileExtension: String {
            switch self {
            case .plain: return "sql"
            case .custom: return "dump"
            case .tar: return "tar"
            case .directory: return ""
            }
        }
    }

    struct Result: Sendable {
        var exitCode: Int32
        var stderr: String
        var bytesWritten: Int
        var elapsed: TimeInterval
    }

    enum CLIError: LocalizedError {
        case binaryNotFound(name: String, searched: [String])
        case binaryTooOld(name: String, serverMajor: Int, found: [String])
        case launchFailed(String)
        case nonZeroExit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let name, let searched):
                return "Couldn't find \(name). Looked in:\n" + searched.joined(separator: "\n")
            case .binaryTooOld(let name, let serverMajor, let found):
                return """
                The server runs PostgreSQL \(serverMajor), but the newest \(name) found is older — \
                \(name) refuses to dump from a newer server. Install PostgreSQL \(serverMajor) client tools \
                (e.g. brew install postgresql@\(serverMajor), or Postgres.app) or set the path in \
                Settings → Binaries.

                Found:
                \(found.joined(separator: "\n"))
                """
            case .launchFailed(let msg):
                return "Failed to launch: \(msg)"
            case .nonZeroExit(let code, let stderr):
                return "Exited with status \(code): \(stderr)"
            }
        }
    }

    // MARK: - Binary discovery

    struct Candidate: Equatable, Sendable {
        let path: String
        let major: Int?
    }

    /// Directories searched, in preference order among equal versions.
    /// Globs (`*`) expand to every installed version.
    static let searchPatterns: [String] = [
        "/Applications/Postgres.app/Contents/Versions/*/bin",
        "/opt/homebrew/opt/postgresql@*/bin",
        "/opt/homebrew/opt/libpq/bin",
        "/opt/homebrew/bin",
        "/usr/local/opt/postgresql@*/bin",
        "/usr/local/opt/libpq/bin",
        "/usr/local/bin",
        "/Library/PostgreSQL/*/bin",
        "/usr/bin",
    ]

    /// Expand `searchPatterns` against the filesystem (one level of `*`).
    static func expandedSearchDirectories(_ patterns: [String] = searchPatterns) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for pattern in patterns {
            guard let star = pattern.firstIndex(of: "*") else { out.append(pattern); continue }
            let parent = String(pattern[..<star])
            let prefix = (parent as NSString).lastPathComponent
            let parentDir = parent.hasSuffix("/") ? String(parent.dropLast()) : (parent as NSString).deletingLastPathComponent
            let namePrefix = parent.hasSuffix("/") ? "" : prefix
            let suffix = String(pattern[pattern.index(after: star)...])
            let entries = ((try? fm.contentsOfDirectory(atPath: parentDir)) ?? [])
                .filter { $0.hasPrefix(namePrefix) }
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for entry in entries {
                out.append(parentDir + "/" + entry + suffix)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// `pg_dump (PostgreSQL) 17.2` → 17; `pg_dump (PostgreSQL) 9.6.24` → 9.
    static func parseMajorVersion(_ versionOutput: String) -> Int? {
        guard let range = versionOutput.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return nil }
        return Int(versionOutput[range].split(separator: ".").first ?? "")
    }

    /// Pick the tool to run. Prefers the highest major version; when the
    /// server version is known, that highest version must be ≥ the server's
    /// (pg_dump refuses newer servers). Pure — candidates come in pre-probed.
    static func select(_ candidates: [Candidate], serverMajor: Int?, name: String) throws -> Candidate {
        guard !candidates.isEmpty else {
            throw CLIError.binaryNotFound(name: name, searched: [])
        }
        // Stable: among equal majors the earlier (preferred location) wins.
        let best = candidates.enumerated().max { a, b in
            let ma = a.element.major ?? -1, mb = b.element.major ?? -1
            if ma != mb { return ma < mb }
            return a.offset > b.offset
        }!.element
        if let serverMajor, let major = best.major, major < serverMajor {
            throw CLIError.binaryTooOld(
                name: name, serverMajor: serverMajor,
                found: candidates.map { "\($0.path) (\($0.major.map(String.init) ?? "unknown"))" })
        }
        return best
    }

    private static func overridePath(for name: String) -> String? {
        guard let override = UserDefaults.standard.string(forKey: "pgbrain.binaryOverride.\(name)"),
              !override.isEmpty,
              FileManager.default.isExecutableFile(atPath: override) else { return nil }
        return override
    }

    private static func executables(named name: String, in directories: [String]) -> [String] {
        let fm = FileManager.default
        var seenTargets = Set<String>()
        var out: [String] = []
        for dir in directories {
            let path = dir + "/" + name
            guard fm.isExecutableFile(atPath: path) else { continue }
            // `latest` symlinks and /opt/homebrew/bin shims point at the
            // same binary as a versioned dir — probe it once.
            let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seenTargets.insert(target).inserted else { continue }
            out.append(path)
        }
        return out
    }

    /// Async, off-thread discovery: honours the Settings override, otherwise
    /// probes `--version` of every installed copy and selects per `select`.
    static func findBinary(named name: String, serverVersionNum: Int? = nil,
                           searchDirectories: [String]? = nil) async throws -> URL {
        if let override = overridePath(for: name) { return URL(fileURLWithPath: override) }
        let dirs = searchDirectories ?? expandedSearchDirectories()
        let paths = executables(named: name, in: dirs)
        guard !paths.isEmpty else {
            throw CLIError.binaryNotFound(name: name, searched: dirs)
        }
        var candidates: [Candidate] = []
        for path in paths {
            let output = try? await run(executable: URL(fileURLWithPath: path), arguments: ["--version"],
                                        environment: [:], timeoutSeconds: 5)
            candidates.append(Candidate(path: path, major: output.flatMap { parseMajorVersion($0.stdout) }))
        }
        let serverMajor = serverVersionNum.map(majorVersion(fromServerVersionNum:))
        return URL(fileURLWithPath: try select(candidates, serverMajor: serverMajor, name: name).path)
    }

    /// `170002` → 17, `90624` → 9.
    static func majorVersion(fromServerVersionNum num: Int) -> Int {
        num / 10_000
    }

    /// Synchronous lookup without version probing (first executable in
    /// preference order). Kept for quick "is it installed?" checks.
    static func locateBinary(named name: String) throws -> URL {
        if let override = overridePath(for: name) { return URL(fileURLWithPath: override) }
        let dirs = expandedSearchDirectories()
        guard let first = executables(named: name, in: dirs).first else {
            throw CLIError.binaryNotFound(name: name, searched: dirs)
        }
        return URL(fileURLWithPath: first)
    }

    // MARK: - Argument building

    /// libpq conninfo value quoting: single quotes, `\` and `'` escaped.
    static func conninfoQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// `--dbname=` carrying a conninfo string, so the name is always data.
    static func dbnameArgument(_ database: String) -> String {
        "--dbname=dbname=" + conninfoQuote(database)
    }

    /// Pure builder for the `pg_dump` argument vector — extracted so it can be
    /// unit-tested without spawning a subprocess. The password is never an
    /// argument (it's passed via a temp `PGPASSFILE`), so this is safe to log.
    static func dumpArguments(
        connection: Connection,
        format: Format,
        destinationPath: String,
        extraArgs: [String] = []
    ) -> [String] {
        var args = [
            "--host=\(connection.host)",
            "--port=\(connection.port)",
            "--username=\(connection.username)",
            "--no-password",
            "--format=\(format.flag)",
            "--file=\(destinationPath)",
        ]
        if !connection.database.isEmpty {
            args.append(dbnameArgument(connection.database))
        }
        args.append(contentsOf: extraArgs)
        return args
    }

    /// Options for `pg_restore`. `clean` drops objects before recreating them;
    /// `singleTransaction` makes the whole restore atomic (and disables
    /// parallel `--jobs`, which Postgres forbids in that mode).
    struct RestoreOptions: Sendable {
        var clean: Bool = false
        var noOwner: Bool = false
        var singleTransaction: Bool = false
        var jobs: Int = 1

        init(clean: Bool = false, noOwner: Bool = false, singleTransaction: Bool = false, jobs: Int = 1) {
            self.clean = clean
            self.noOwner = noOwner
            self.singleTransaction = singleTransaction
            self.jobs = jobs
        }
    }

    /// Pure builder for the `pg_restore` argument vector. Restores `archivePath`
    /// (a custom/directory/tar archive) into `dbname`.
    static func restoreArguments(
        connection: Connection,
        dbname: String,
        archivePath: String,
        options: RestoreOptions = RestoreOptions()
    ) -> [String] {
        var args = [
            "--host=\(connection.host)",
            "--port=\(connection.port)",
            "--username=\(connection.username)",
            "--no-password",
            dbnameArgument(dbname),
        ]
        if options.clean { args.append(contentsOf: ["--clean", "--if-exists"]) }
        if options.noOwner { args.append("--no-owner") }
        if options.singleTransaction {
            // `--jobs` is incompatible with a single transaction.
            args.append("--single-transaction")
        } else if options.jobs > 1 {
            args.append("--jobs=\(options.jobs)")
        }
        // `--` so an archive path starting with `-` stays positional.
        args.append("--")
        args.append(archivePath)
        return args
    }

    /// Environment for the tool: the app's environment minus every `PG*`
    /// variable, plus TLS settings, the tunnel address and the passfile.
    static func environment(
        for connection: Connection, tunnelPort: Int?, passfile: String?,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("PG") }
        env["PGSSLMODE"] = connection.sslMode.rawValue
        env["PGAPPNAME"] = "pgBrain"
        env["PGCONNECT_TIMEOUT"] = "10"
        if let v = Connection.expandedPath(connection.sslRootCertPath) { env["PGSSLROOTCERT"] = v }
        if let v = Connection.expandedPath(connection.sslClientCertPath) { env["PGSSLCERT"] = v }
        if let v = Connection.expandedPath(connection.sslClientKeyPath) { env["PGSSLKEY"] = v }
        if let tunnelPort {
            // libpq connects to hostaddr but verifies the certificate
            // against `--host`, so verify-full keeps working over SSH.
            env["PGHOSTADDR"] = "127.0.0.1"
            env["PGPORT"] = String(tunnelPort)
        }
        if let passfile { env["PGPASSFILE"] = passfile }
        return env
    }

    /// One `.pgpass` line matching any host/port/db/user.
    static func pgpassLine(password: String) -> String {
        let escaped = password.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
        return "*:*:*:*:\(escaped)\n"
    }

    // MARK: - Running

    /// Run `pg_restore`, reading `archive` into the target database. Surfaces
    /// the same `Result`/error shape as `dump` (`bytesWritten` is 0 — restore
    /// writes to the database, not a file).
    static func restore(
        connection: Connection,
        password: String,
        dbname: String,
        archive: URL,
        options: RestoreOptions = RestoreOptions(),
        serverVersionNum: Int? = nil
    ) async throws -> Result {
        let started = Date()
        let knownVersion = await resolvedServerVersion(serverVersionNum, connection)
        let binary = try await findBinary(named: "pg_restore", serverVersionNum: knownVersion)
        var args = restoreArguments(connection: connection, dbname: dbname,
                                    archivePath: archive.path, options: options)
        return try await withTunnel(for: connection) { tunnelPort in
            if tunnelPort != nil { args.removeAll { $0.hasPrefix("--port=") } }
            return try await runTool(binary: binary, args: args, connection: connection, password: password,
                                     tunnelPort: tunnelPort, output: nil, started: started)
        }
    }

    static func dump(
        connection: Connection,
        password: String,
        format: Format,
        destination: URL,
        extraArgs: [String] = [],
        serverVersionNum: Int? = nil
    ) async throws -> Result {
        let started = Date()
        let knownVersion = await resolvedServerVersion(serverVersionNum, connection)
        let binary = try await findBinary(named: "pg_dump", serverVersionNum: knownVersion)
        var args = dumpArguments(connection: connection, format: format,
                                 destinationPath: destination.path, extraArgs: extraArgs)
        return try await withTunnel(for: connection) { tunnelPort in
            if tunnelPort != nil { args.removeAll { $0.hasPrefix("--port=") } }
            return try await runTool(binary: binary, args: args, connection: connection, password: password,
                                     tunnelPort: tunnelPort, output: destination, started: started)
        }
    }

    private static func resolvedServerVersion(_ explicit: Int?, _ connection: Connection) async -> Int? {
        if let explicit { return explicit }
        return await MainActor.run { ConnectionService.knownServerVersionNum(for: connection.id) }
    }

    /// Hold the connection's SSH tunnel (if any) for the duration of `body`.
    private static func withTunnel<T: Sendable>(
        for connection: Connection, _ body: (Int?) async throws -> T
    ) async throws -> T {
        guard connection.sshEnabled else { return try await body(nil) }
        let owner = "pgtool-\(UUID().uuidString)"
        let endpoint = try await ConnectionService.openEndpoint(for: connection, owner: owner)
        do {
            let result = try await body(endpoint.port)
            await MainActor.run { ConnectionService.releaseEndpoint(for: connection, owner: owner) }
            return result
        } catch {
            await MainActor.run { ConnectionService.releaseEndpoint(for: connection, owner: owner) }
            throw error
        }
    }

    static func runTool(
        binary: URL, args: [String], connection: Connection, password: String,
        tunnelPort: Int?, output: URL?, started: Date
    ) async throws -> Result {
        var passfile: URL?
        if !password.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("pgbrain-\(UUID().uuidString).pgpass")
            try AppSupport.createPrivateFile(at: url, contents: Data(pgpassLine(password: password).utf8))
            passfile = url
        }
        defer { if let passfile { try? FileManager.default.removeItem(at: passfile) } }

        let outputSnapshot = output.map(FileSnapshot.init(url:))
        let env = environment(for: connection, tunnelPort: tunnelPort, passfile: passfile?.path)
        do {
            let run = try await run(executable: binary, arguments: args, environment: env, timeoutSeconds: nil)
            try Task.checkCancellation()
            let bytes = output.map { Self.size(of: $0) } ?? 0
            let result = Result(exitCode: run.status, stderr: run.stderr, bytesWritten: bytes,
                                elapsed: Date().timeIntervalSince(started))
            if run.status != 0 {
                outputSnapshot?.removeIfChanged()
                throw CLIError.nonZeroExit(run.status, run.stderr)
            }
            return result
        } catch {
            outputSnapshot?.removeIfChanged()
            throw error
        }
    }

    /// Size of a file, or total size of a directory-format dump.
    private static func size(of url: URL) -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        }
        let files = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let f = files?.nextObject() as? URL {
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Remembers whether the output existed before the run so a failed run
    /// deletes only what it wrote (a partial dump), not an untouched file.
    private struct FileSnapshot {
        let url: URL
        let existed: Bool
        let modified: Date?

        init(url: URL) {
            self.url = url
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            existed = attrs != nil
            modified = attrs?[.modificationDate] as? Date
        }

        func removeIfChanged() {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let attrs else { return }
            let nowModified = attrs[.modificationDate] as? Date
            if !existed || nowModified != modified {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    struct ProcessOutput: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Run a process without blocking a cooperative thread: completion comes
    /// from `terminationHandler`, output is drained continuously (no pipe
    /// deadlock), and cancelling the calling task terminates the process.
    static func run(executable: URL, arguments: [String], environment: [String: String],
                    timeoutSeconds: Double?) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        let outBuf = OutputBuffer(), errBuf = OutputBuffer()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let box = ProcessBox(process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                let gate = ResumeGate()
                let drained = DispatchGroup()
                for (pipe, buf) in [(outPipe, outBuf), (errPipe, errBuf)] {
                    drained.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            drained.leave()
                        } else {
                            buf.append(chunk)
                        }
                    }
                }
                process.terminationHandler = { p in
                    let status = p.terminationStatus
                    // Wait for EOF on both pipes so no trailing stderr is lost —
                    // but bounded: an orphaned grandchild can hold the pipe open.
                    DispatchQueue.global().async {
                        _ = drained.wait(timeout: .now() + 2)
                        guard gate.claim() else { return }
                        continuation.resume(returning: ProcessOutput(status: status, stdout: outBuf.string, stderr: errBuf.string))
                    }
                }
                do {
                    try process.run()
                } catch {
                    for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil }
                    if gate.claim() { continuation.resume(throwing: CLIError.launchFailed(error.localizedDescription)) }
                    return
                }
                // onCancel may have fired before there was a process to stop.
                if Task.isCancelled { box.terminate() }
                if let timeoutSeconds {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                        box.terminate()
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

/// Lets a `Process` be terminated from a `@Sendable` cancellation handler.
final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
