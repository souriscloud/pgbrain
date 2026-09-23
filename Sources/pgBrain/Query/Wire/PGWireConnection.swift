import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Where and how a scratchpad session connects. Mirrors what
/// `ConnectionService` hands PostgresNIO, including the libpq-style SSL mode
/// mapping, so the session reaches the same server the pool does.
struct PGWireEndpoint: Sendable {
    var host: String
    var port: Int
    /// Name used for SNI / certificate verification. When the connection runs
    /// through an SSH tunnel `host` is 127.0.0.1 but the certificate still
    /// names the real server.
    var tlsServerName: String?
    var username: String
    var password: String?
    var database: String?
    var sslMode: Connection.SSLMode
    var applicationName: String = "pgBrain"
    var connectTimeoutSeconds: Int64 = 8
}

/// One result set produced by a simple-query round trip.
struct PGWireResultSet: Sendable {
    var fields: [PGField]
    var rows: [[String?]] = []
    var truncated = false
    var commandTag: String?
}

struct PGWireOutcome: Sendable {
    var sets: [PGWireResultSet] = []
    var error: PGServerError?
    var notices: [PGServerError] = []
    /// ReadyForQuery status byte: 'I' idle, 'T' in a transaction block,
    /// 'E' in a failed transaction block.
    var status: UInt8 = UInt8(ascii: "I")
}

enum PGWireTransport {
    typealias Channel = NIOAsyncChannel<PGBackendMessage, ByteBuffer>

    static func open(_ endpoint: PGWireEndpoint) async throws -> Channel {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(endpoint.connectTimeoutSeconds))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .connect(host: endpoint.host, port: endpoint.port)
            .get()
        do {
            if endpoint.sslMode != .disable {
                try await negotiateTLS(on: channel, endpoint: endpoint)
            }
            return try await channel.eventLoop.submit {
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(PGBackendDecoder()))
                return try Channel(wrappingChannelSynchronously: channel)
            }.get()
        } catch {
            channel.close(promise: nil)
            throw error
        }
    }

    /// Sends a CancelRequest for `pid` on a brand-new socket — the protocol's
    /// out-of-band cancel. Needs no pooled connection and can only ever hit
    /// the backend that owns `secret`.
    static func sendCancel(to endpoint: PGWireEndpoint, pid: Int32, secret: ByteBuffer) async throws {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(endpoint.connectTimeoutSeconds))
            .connect(host: endpoint.host, port: endpoint.port)
            .get()
        try await channel.writeAndFlush(PGFrontend.cancelRequest(pid: pid, secret: secret))
        try? await channel.close()
    }

    private static func negotiateTLS(on channel: any NIOCore.Channel, endpoint: PGWireEndpoint) async throws {
        let promise = channel.eventLoop.makePromise(of: UInt8.self)
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(SSLResponseHandler(promise: promise))
        }.get()
        try await channel.writeAndFlush(PGFrontend.sslRequest())
        let answer = try await promise.futureResult.get()
        guard answer == UInt8(ascii: "S") else {
            switch endpoint.sslMode {
            case .disable, .allow, .prefer: return
            case .require, .verifyCA, .verifyFull: throw PGWireError.sslRefused
            }
        }
        var tls = TLSConfiguration.makeClientConfiguration()
        switch endpoint.sslMode {
        case .disable, .allow, .prefer, .require: tls.certificateVerification = .none
        case .verifyCA: tls.certificateVerification = .noHostnameVerification
        case .verifyFull: tls.certificateVerification = .fullVerification
        }
        let context = try NIOSSLContext(configuration: tls)
        let name = endpoint.tlsServerName ?? endpoint.host
        let sni: String? = isIPAddress(name) ? nil : name
        try await channel.eventLoop.submit {
            let handler = try NIOSSLClientHandler(context: context, serverHostname: sni)
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }.get()
    }

    private static func isIPAddress(_ s: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, s, &v4) == 1 || inet_pton(AF_INET6, s, &v6) == 1
    }
}

/// Reads the single-byte answer to SSLRequest, then gets out of the way.
private final class SSLResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<UInt8>
    private var done = false

    init(promise: EventLoopPromise<UInt8>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard !done, let byte: UInt8 = buffer.readInteger() else { return }
        done = true
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        promise.succeed(byte)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; promise.fail(PGWireError.connectionClosed) }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !done { done = true; promise.fail(error) }
        context.fireErrorCaught(error)
    }
}

/// The protocol conversation over one open channel. Lives entirely inside the
/// session driver task, so it needs no synchronisation of its own.
struct PGWireIO {
    var inbound: NIOAsyncChannelInboundStream<PGBackendMessage>.AsyncIterator
    let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    var backendPID: Int32 = 0
    var backendSecret = ByteBuffer()
    var parameters: [String: String] = [:]

    mutating func next() async throws -> PGBackendMessage {
        guard let message = try await inbound.next() else { throw PGWireError.connectionClosed }
        return message
    }

    mutating func startup(_ endpoint: PGWireEndpoint) async throws {
        var params: [(String, String)] = [("user", endpoint.username)]
        if let db = endpoint.database, !db.isEmpty { params.append(("database", db)) }
        params.append(("application_name", endpoint.applicationName))
        params.append(("client_encoding", "UTF8"))
        try await outbound.write(PGFrontend.startup(parameters: params))

        var scram: PGScramSHA256?
        while true {
            switch try await next() {
            case .authentication(let code, var data):
                switch code {
                case 0:
                    break
                case 3:
                    try await outbound.write(PGFrontend.password(try requirePassword(endpoint)))
                case 5:
                    guard let salt = data.readBytes(length: 4) else {
                        throw PGWireError.protocolViolation("short MD5 salt")
                    }
                    let reply = PGMD5Auth.response(user: endpoint.username, password: try requirePassword(endpoint), salt: salt)
                    try await outbound.write(PGFrontend.password(reply))
                case 10:
                    var mechanisms: [String] = []
                    while let m = data.readNullTerminatedString(), !m.isEmpty { mechanisms.append(m) }
                    guard mechanisms.contains(PGScramSHA256.mechanism) else {
                        throw PGWireError.unsupportedAuthentication("SASL " + mechanisms.joined(separator: ", "))
                    }
                    let client = PGScramSHA256(password: try requirePassword(endpoint))
                    scram = client
                    try await outbound.write(PGFrontend.saslInitialResponse(
                        mechanism: PGScramSHA256.mechanism, data: Array(client.clientFirstMessage.utf8)))
                case 11:
                    guard var client = scram else { throw PGWireError.protocolViolation("unexpected SASLContinue") }
                    let serverFirst = data.readString(length: data.readableBytes) ?? ""
                    let final = try client.clientFinalMessage(serverFirst: serverFirst)
                    scram = client
                    try await outbound.write(PGFrontend.saslResponse(Array(final.utf8)))
                case 12:
                    let serverFinal = data.readString(length: data.readableBytes) ?? ""
                    guard let client = scram, client.verify(serverFinal: serverFinal) else {
                        throw PGWireError.authenticationFailed("server signature mismatch")
                    }
                case 7, 8: throw PGWireError.unsupportedAuthentication("GSSAPI")
                case 9: throw PGWireError.unsupportedAuthentication("SSPI")
                case 2: throw PGWireError.unsupportedAuthentication("Kerberos V5")
                default: throw PGWireError.unsupportedAuthentication("code \(code)")
                }
            case .backendKeyData(let pid, let secret):
                backendPID = pid
                backendSecret = secret
            case .parameterStatus(let name, let value):
                parameters[name] = value
            case .error(let err):
                if err.sqlState == "28P01" || err.sqlState == "28000" {
                    throw PGWireError.authenticationFailed(err.message)
                }
                throw err
            case .readyForQuery:
                return
            default:
                continue
            }
        }
    }

    private func requirePassword(_ endpoint: PGWireEndpoint) throws -> String {
        guard let pw = endpoint.password, !pw.isEmpty else {
            throw PGWireError.authenticationFailed("the server asked for a password but none is saved for this connection")
        }
        return pw
    }

    /// One simple-query round trip. Always drains to ReadyForQuery so the
    /// connection stays in sync even after an error or a cancel. Rows beyond
    /// `rowLimit` are read off the wire and dropped, so memory stays bounded
    /// no matter what the statement returns.
    mutating func simpleQuery(_ sql: String, rowLimit: Int) async throws -> PGWireOutcome {
        try await outbound.write(PGFrontend.query(sql))
        var outcome = PGWireOutcome()
        var current: PGWireResultSet?
        while true {
            switch try await next() {
            case .rowDescription(let fields):
                current = PGWireResultSet(fields: fields)
            case .dataRow(let raw):
                if current == nil { current = PGWireResultSet(fields: []) }
                if current!.rows.count < rowLimit {
                    current!.rows.append(PGBackendDecoder.decodeTextRow(raw))
                } else {
                    current!.truncated = true
                }
            case .commandComplete(let tag):
                var set = current ?? PGWireResultSet(fields: [])
                set.commandTag = tag
                outcome.sets.append(set)
                current = nil
            case .emptyQuery:
                current = nil
            case .error(let err):
                if let partial = current { outcome.sets.append(partial) }
                current = nil
                outcome.error = err
            case .notice(let notice):
                if outcome.notices.count < 200 { outcome.notices.append(notice) }
            case .parameterStatus(let name, let value):
                parameters[name] = value
            case .copyInResponse:
                try await outbound.write(PGFrontend.copyFail("COPY FROM STDIN is not supported in the scratchpad — use Import instead"))
            case .copyOutResponse:
                current = PGWireResultSet(fields: [PGField(name: "COPY", typeOID: 25, typeModifier: -1)])
            case .copyData(var data):
                if current == nil { current = PGWireResultSet(fields: [PGField(name: "COPY", typeOID: 25, typeModifier: -1)]) }
                if current!.rows.count < rowLimit {
                    var line = data.readString(length: data.readableBytes) ?? ""
                    if line.hasSuffix("\n") { line.removeLast() }
                    current!.rows.append([line])
                } else {
                    current!.truncated = true
                }
            case .copyBothResponse:
                throw PGWireError.protocolViolation("replication (CopyBoth) is not supported in the scratchpad")
            case .readyForQuery(let status):
                if let partial = current { outcome.sets.append(partial) }
                outcome.status = status
                return outcome
            case .copyDone, .notification, .backendKeyData, .authentication, .other:
                continue
            }
        }
    }

    func terminate() async {
        try? await outbound.write(PGFrontend.terminate())
    }
}
