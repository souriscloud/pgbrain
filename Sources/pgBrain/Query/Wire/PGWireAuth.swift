import CommonCrypto
import CryptoKit
import Foundation

enum PGMD5Auth {
    /// `"md5" + md5hex(md5hex(password + user) + salt)` — the pre-SCRAM scheme.
    static func response(user: String, password: String, salt: [UInt8]) -> String {
        let inner = hex(Insecure.MD5.hash(data: Array((password + user).utf8)))
        let outer = hex(Insecure.MD5.hash(data: Array(inner.utf8) + salt))
        return "md5" + outer
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// SCRAM-SHA-256 (RFC 5802 / 7677) client, without channel binding. The
/// server takes the user from the startup packet, so libpq sends an empty
/// `n=` — `username` is only a parameter so the RFC test vector can run.
struct PGScramSHA256 {
    static let mechanism = "SCRAM-SHA-256"

    let password: String
    let clientNonce: String
    let username: String
    private(set) var authMessage = ""
    private(set) var saltedPassword: [UInt8] = []

    init(password: String, clientNonce: String? = nil, username: String = "") {
        self.password = password
        self.username = username
        if let clientNonce {
            self.clientNonce = clientNonce
        } else {
            var bytes = [UInt8](repeating: 0, count: 18)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            self.clientNonce = Data(bytes).base64EncodedString()
        }
    }

    var clientFirstBare: String { "n=\(username),r=\(clientNonce)" }
    var clientFirstMessage: String { "n,," + clientFirstBare }

    mutating func clientFinalMessage(serverFirst: String) throws -> String {
        let attrs = Self.attributes(serverFirst)
        guard let nonce = attrs["r"], nonce.hasPrefix(clientNonce),
              let saltB64 = attrs["s"], let salt = Data(base64Encoded: saltB64),
              let iterText = attrs["i"], let iterations = Int(iterText), iterations > 0
        else { throw PGWireError.authenticationFailed("malformed SCRAM server-first message") }
        saltedPassword = Self.pbkdf2(password: Array(password.utf8), salt: Array(salt), rounds: iterations)
        let clientFinalWithoutProof = "c=biws,r=\(nonce)"
        authMessage = clientFirstBare + "," + serverFirst + "," + clientFinalWithoutProof
        let clientKey = Self.hmac(key: saltedPassword, Array("Client Key".utf8))
        let storedKey = Array(SHA256.hash(data: clientKey))
        let signature = Self.hmac(key: storedKey, Array(authMessage.utf8))
        let proof = zip(clientKey, signature).map { $0 ^ $1 }
        return clientFinalWithoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    func verify(serverFinal: String) -> Bool {
        let attrs = Self.attributes(serverFinal)
        guard let v = attrs["v"], let expected = Data(base64Encoded: v) else { return false }
        let serverKey = Self.hmac(key: saltedPassword, Array("Server Key".utf8))
        let signature = Self.hmac(key: serverKey, Array(authMessage.utf8))
        return Array(expected) == signature
    }

    private static func attributes(_ message: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in message.split(separator: ",") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            out[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        return out
    }

    private static func hmac(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func pbkdf2(password: [UInt8], salt: [UInt8], rounds: Int) -> [UInt8] {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: Int8.self) { pwChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwChars.baseAddress, password.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    &derived, derived.count
                )
            }
        }
        return status == kCCSuccess ? derived : []
    }
}
