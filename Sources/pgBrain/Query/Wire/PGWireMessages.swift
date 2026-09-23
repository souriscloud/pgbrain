import Foundation
import NIOCore

/// Minimal PostgreSQL v3 wire protocol, just enough for the scratchpad's
/// pinned session. PostgresNIO only speaks the extended protocol and always
/// asks for *binary* results, which breaks every type it can't decode
/// (`aclitem` has no binary output at all). The simple-query protocol always
/// returns the server's text rendering — byte-for-byte what psql prints — and
/// also hands us ReadyForQuery's transaction status and the BackendKeyData
/// needed for a real wire-level CancelRequest.

struct PGField: Sendable, Equatable {
    var name: String
    var typeOID: UInt32
    var typeModifier: Int32
}

/// ErrorResponse / NoticeResponse payload, keyed by the protocol field codes
/// ('S' severity, 'C' SQLSTATE, 'M' message, 'D' detail, 'H' hint, 'P'
/// position, 'W' where, …).
struct PGServerError: Error, Sendable, LocalizedError, Equatable {
    var fields: [UInt8: String]

    subscript(_ code: Character) -> String? {
        guard let ascii = code.asciiValue else { return nil }
        return fields[ascii]
    }

    var severity: String { self["V"] ?? self["S"] ?? "ERROR" }
    var sqlState: String? { self["C"] }
    var message: String { self["M"] ?? "unknown server error" }
    var position: Int? { self["P"].flatMap(Int.init) }

    var isQueryCanceled: Bool { sqlState == "57014" }

    /// Same shape `PostgresErrorMessage` produces for PostgresNIO errors so
    /// the scratchpad reads identically whichever path ran the statement.
    var errorDescription: String? {
        var out = message
        if let code = sqlState { out += " [\(code)]" }
        if let detail = self["D"] { out += "\n\nDetail: \(detail)" }
        if let hint = self["H"] { out += "\n\nHint: \(hint)" }
        if let pos = position { out += "\n\nPosition: \(pos)" }
        if let whereText = self["W"] { out += "\n\nWhere: \(whereText)" }
        return out
    }

    /// One-line rendering for notices (`NOTICE: relation exists, skipping`).
    var noticeLine: String { "\(severity): \(message)" }
}

enum PGWireError: Error, LocalizedError, Sendable, Equatable {
    case protocolViolation(String)
    case connectionClosed
    case sslRefused
    case unsupportedAuthentication(String)
    case authenticationFailed(String)
    case sessionClosed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .protocolViolation(let what): return "Protocol error: \(what)"
        case .connectionClosed: return "The session's connection was lost. The next run opens a fresh session (any open transaction was rolled back by the server)."
        case .sslRefused: return "The server does not accept SSL connections, but the connection's SSL mode requires it."
        case .unsupportedAuthentication(let method): return "Unsupported authentication method: \(method)"
        case .authenticationFailed(let why): return "Authentication failed: \(why)"
        case .sessionClosed: return "The scratchpad session was closed."
        case .cancelled: return "Cancelled"
        }
    }
}

enum PGBackendMessage: Sendable {
    case authentication(code: Int32, data: ByteBuffer)
    case backendKeyData(pid: Int32, secret: ByteBuffer)
    case parameterStatus(name: String, value: String)
    case readyForQuery(UInt8)
    case rowDescription([PGField])
    case dataRow(ByteBuffer)
    case commandComplete(String)
    case emptyQuery
    case error(PGServerError)
    case notice(PGServerError)
    case notification(channel: String, payload: String)
    case copyInResponse
    case copyOutResponse
    case copyBothResponse
    case copyData(ByteBuffer)
    case copyDone
    case other(UInt8)
}

struct PGBackendDecoder: ByteToMessageDecoder {
    typealias InboundOut = PGBackendMessage

    /// Guards against a corrupt length word making us buffer gigabytes.
    static let maxMessageLength = 1 << 30

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let start = buffer.readerIndex
        guard let type: UInt8 = buffer.getInteger(at: start),
              let length: Int32 = buffer.getInteger(at: start + 1) else { return .needMoreData }
        guard length >= 4, Int(length) <= Self.maxMessageLength else {
            throw PGWireError.protocolViolation("invalid message length \(length)")
        }
        guard buffer.readableBytes >= 1 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 5)
        guard var payload = buffer.readSlice(length: Int(length) - 4) else { return .needMoreData }
        let message = try Self.parse(type: type, payload: &payload)
        context.fireChannelRead(wrapInboundOut(message))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        return .needMoreData
    }

    static func parse(type: UInt8, payload: inout ByteBuffer) throws -> PGBackendMessage {
        switch type {
        case UInt8(ascii: "R"):
            guard let code: Int32 = payload.readInteger() else { throw PGWireError.protocolViolation("short Authentication") }
            return .authentication(code: code, data: payload)
        case UInt8(ascii: "K"):
            guard let pid: Int32 = payload.readInteger() else { throw PGWireError.protocolViolation("short BackendKeyData") }
            return .backendKeyData(pid: pid, secret: payload)
        case UInt8(ascii: "S"):
            let name = payload.readNullTerminatedString() ?? ""
            let value = payload.readNullTerminatedString() ?? ""
            return .parameterStatus(name: name, value: value)
        case UInt8(ascii: "Z"):
            return .readyForQuery(payload.readInteger() ?? UInt8(ascii: "I"))
        case UInt8(ascii: "T"):
            guard let count: Int16 = payload.readInteger(), count >= 0 else {
                throw PGWireError.protocolViolation("short RowDescription")
            }
            var fields: [PGField] = []
            fields.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let name = payload.readNullTerminatedString(),
                      let (_, _, typeOID, _, typmod, _) = payload.readMultipleIntegers(
                        as: (UInt32, Int16, UInt32, Int16, Int32, Int16).self)
                else { throw PGWireError.protocolViolation("short RowDescription field") }
                fields.append(PGField(name: name, typeOID: typeOID, typeModifier: typmod))
            }
            return .rowDescription(fields)
        case UInt8(ascii: "D"):
            return .dataRow(payload)
        case UInt8(ascii: "C"):
            return .commandComplete(payload.readNullTerminatedString() ?? "")
        case UInt8(ascii: "I"):
            return .emptyQuery
        case UInt8(ascii: "E"):
            return .error(parseFields(&payload))
        case UInt8(ascii: "N"):
            return .notice(parseFields(&payload))
        case UInt8(ascii: "A"):
            _ = payload.readInteger(as: Int32.self)
            let channel = payload.readNullTerminatedString() ?? ""
            let body = payload.readNullTerminatedString() ?? ""
            return .notification(channel: channel, payload: body)
        case UInt8(ascii: "G"):
            return .copyInResponse
        case UInt8(ascii: "H"):
            return .copyOutResponse
        case UInt8(ascii: "W"):
            return .copyBothResponse
        case UInt8(ascii: "d"):
            return .copyData(payload)
        case UInt8(ascii: "c"):
            return .copyDone
        default:
            return .other(type)
        }
    }

    private static func parseFields(_ payload: inout ByteBuffer) -> PGServerError {
        var fields: [UInt8: String] = [:]
        while let code: UInt8 = payload.readInteger(), code != 0 {
            fields[code] = payload.readNullTerminatedString() ?? ""
        }
        return PGServerError(fields: fields)
    }

    /// Text-format DataRow → one optional string per column. NULL is the
    /// only case with length -1; everything else is the server's text output.
    static func decodeTextRow(_ row: ByteBuffer) -> [String?] {
        var row = row
        guard let count: Int16 = row.readInteger(), count > 0 else { return [] }
        var out: [String?] = []
        out.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let length: Int32 = row.readInteger() else { break }
            if length < 0 {
                out.append(nil)
            } else {
                out.append(row.readString(length: Int(length)) ?? "")
            }
        }
        return out
    }
}

enum PGFrontend {
    static let protocolVersion: Int32 = 196_608
    static let sslRequestCode: Int32 = 80_877_103
    static let cancelRequestCode: Int32 = 80_877_102

    static func startup(parameters: [(String, String)]) -> ByteBuffer {
        var body = ByteBuffer()
        body.writeInteger(protocolVersion)
        for (key, value) in parameters {
            body.writeNullTerminatedString(key)
            body.writeNullTerminatedString(value)
        }
        body.writeInteger(UInt8(0))
        var out = ByteBuffer()
        out.writeInteger(Int32(body.readableBytes + 4))
        out.writeBuffer(&body)
        return out
    }

    static func sslRequest() -> ByteBuffer {
        var out = ByteBuffer()
        out.writeInteger(Int32(8))
        out.writeInteger(sslRequestCode)
        return out
    }

    static func cancelRequest(pid: Int32, secret: ByteBuffer) -> ByteBuffer {
        var secret = secret
        var out = ByteBuffer()
        out.writeInteger(Int32(12 + secret.readableBytes))
        out.writeInteger(cancelRequestCode)
        out.writeInteger(pid)
        out.writeBuffer(&secret)
        return out
    }

    static func query(_ sql: String) -> ByteBuffer {
        message(UInt8(ascii: "Q")) { $0.writeNullTerminatedString(sql) }
    }

    static func password(_ text: String) -> ByteBuffer {
        message(UInt8(ascii: "p")) { $0.writeNullTerminatedString(text) }
    }

    static func saslInitialResponse(mechanism: String, data: [UInt8]) -> ByteBuffer {
        message(UInt8(ascii: "p")) {
            $0.writeNullTerminatedString(mechanism)
            $0.writeInteger(Int32(data.count))
            $0.writeBytes(data)
        }
    }

    static func saslResponse(_ data: [UInt8]) -> ByteBuffer {
        message(UInt8(ascii: "p")) { $0.writeBytes(data) }
    }

    static func copyFail(_ reason: String) -> ByteBuffer {
        message(UInt8(ascii: "f")) { $0.writeNullTerminatedString(reason) }
    }

    static func terminate() -> ByteBuffer {
        message(UInt8(ascii: "X")) { _ in }
    }

    private static func message(_ type: UInt8, _ fill: (inout ByteBuffer) -> Void) -> ByteBuffer {
        var body = ByteBuffer()
        fill(&body)
        var out = ByteBuffer()
        out.writeInteger(type)
        out.writeInteger(Int32(body.readableBytes + 4))
        out.writeBuffer(&body)
        return out
    }
}
