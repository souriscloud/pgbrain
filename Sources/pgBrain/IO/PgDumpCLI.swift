import Foundation

/// Wrapper around the `pg_dump` / `pg_restore` command-line tools. Discovers
/// binaries from common install locations on macOS (Postgres.app, Homebrew,
/// Apple's Library/PostgreSQL) and lets iter-11 Settings override the path.
///
/// Each invocation runs in a `Process` subprocess with stdout/stderr piped
/// back; we surface them line-by-line via an `AsyncStream` so the UI can
/// show live progress without leaking pipe buffers.
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
        case launchFailed(String)
        case nonZeroExit(Int32, String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let name, let searched):
                return "Couldn't find \(name). Looked in:\n" + searched.joined(separator: "\n")
            case .launchFailed(let msg):
                return "Failed to launch: \(msg)"
            case .nonZeroExit(let code, let stderr):
                return "Exited with status \(code): \(stderr)"
            }
        }
    }

    /// Find the pg_dump (or pg_restore / psql) binary. Prefer the override
    /// path from UserDefaults if present; otherwise walk a small list of the
    /// usual macOS install locations.
    static func locateBinary(named name: String) throws -> URL {
        let defaultsKey = "pgbrain.binaryOverride.\(name)"
        if let override = UserDefaults.standard.string(forKey: defaultsKey),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let candidates: [String] = [
            // Postgres.app — latest first.
            "/Applications/Postgres.app/Contents/Versions/latest/bin/\(name)",
            "/Applications/Postgres.app/Contents/Versions/17/bin/\(name)",
            "/Applications/Postgres.app/Contents/Versions/16/bin/\(name)",
            "/Applications/Postgres.app/Contents/Versions/15/bin/\(name)",
            // Homebrew (Apple Silicon).
            "/opt/homebrew/bin/\(name)",
            "/opt/homebrew/opt/postgresql@17/bin/\(name)",
            "/opt/homebrew/opt/postgresql@16/bin/\(name)",
            "/opt/homebrew/opt/postgresql@15/bin/\(name)",
            // Homebrew (Intel).
            "/usr/local/bin/\(name)",
            "/usr/local/opt/postgresql@17/bin/\(name)",
            "/usr/local/opt/postgresql@16/bin/\(name)",
            // EnterpriseDB / PostgreSQL.org installers.
            "/Library/PostgreSQL/17/bin/\(name)",
            "/Library/PostgreSQL/16/bin/\(name)",
            // System PATH fallback.
            "/usr/bin/\(name)",
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CLIError.binaryNotFound(name: name, searched: candidates)
    }

    /// Run `pg_dump` for `connection` writing to `destination`. `password` is
    /// piped via the `PGPASSWORD` env var so it never appears on the command
    /// line (visible in `ps`).
    static func dump(
        connection: Connection,
        password: String,
        format: Format,
        destination: URL,
        extraArgs: [String] = []
    ) async throws -> Result {
        let started = Date()
        let binary = try locateBinary(named: "pg_dump")

        var args = [
            "--host", connection.host,
            "--port", String(connection.port),
            "--username", connection.username,
            "--no-password",
            "--format", format.flag,
            "--file", destination.path,
        ]
        if !connection.database.isEmpty {
            args.append(connection.database)
        }
        args.append(contentsOf: extraArgs)

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        if !password.isEmpty { env["PGPASSWORD"] = password }
        process.environment = env

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIError.launchFailed(error.localizedDescription)
        }

        // Drain stderr concurrently to prevent pipe blocking on large output.
        let stderr = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
        process.waitUntilExit()

        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        let result = Result(
            exitCode: process.terminationStatus,
            stderr: stderr,
            bytesWritten: bytes,
            elapsed: Date().timeIntervalSince(started)
        )
        if result.exitCode != 0 {
            throw CLIError.nonZeroExit(result.exitCode, stderr)
        }
        return result
    }
}
