import Foundation
import PostgresNIO

/// Translates the various PostgresNIO error wrappers into a one-line
/// human-readable reason. The default `localizedDescription` on
/// `PostgresTransactionError` reads "PostgresNIO.PostgresTransactionError
/// error 1.", which is useless to anyone trying to figure out why their
/// `Apply` just rolled back. This helper walks through the wrapper to find
/// the inner `PSQLError`, then pulls the server's `Message` field (or the
/// underlying transport error) so the UI surfaces "duplicate key value
/// violates unique constraint …" instead of error-code soup.
enum PostgresErrorMessage {
    static func describe(_ error: any Error) -> String {
        if let txn = error as? PostgresTransactionError {
            return describeTransaction(txn)
        }
        if let psql = error as? PSQLError {
            return describePSQL(psql)
        }
        return error.localizedDescription
    }

    private static func describeTransaction(_ error: PostgresTransactionError) -> String {
        // Order matches PostgresNIO's lifecycle: BEGIN → closure → COMMIT,
        // with a rollback on failure. The first non-nil error is the one
        // the user actually wants to read.
        if let closure = error.closureError {
            return "Transaction rolled back — " + describe(closure)
        }
        if let begin = error.beginError {
            return "Couldn't BEGIN — " + describe(begin)
        }
        if let commit = error.commitError {
            return "COMMIT failed — " + describe(commit)
        }
        if let rollback = error.rollbackError {
            return "ROLLBACK failed — " + describe(rollback)
        }
        return "PostgresTransactionError (no inner error)"
    }

    private static func describePSQL(_ error: PSQLError) -> String {
        if let server = error.serverInfo {
            let msg = server[.message] ?? "unknown server error"
            // Attach the SQLSTATE code so the user can grep PG docs.
            let sqlState = server[.sqlState].map { " [\($0)]" } ?? ""
            // Detail / Hint live in optional fields — surface them
            // because PG often puts the actionable bit there.
            let detail = server[.detail].map { "\n\nDetail: \($0)" } ?? ""
            let hint = server[.hint].map { "\n\nHint: \($0)" } ?? ""
            return "\(msg)\(sqlState)\(detail)\(hint)"
        }
        if let underlying = error.underlying {
            return String(describing: underlying)
        }
        return "PSQLError(\(error.code))"
    }
}
