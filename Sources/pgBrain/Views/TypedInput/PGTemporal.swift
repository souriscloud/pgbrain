import Foundation

/// Lossless model of a Postgres date / time / timestamp text value in the
/// default ISO `DateStyle`. `Date` can't carry what the server sends
/// (microseconds, the original offset, BC years, ±infinity), so the editor
/// parses into this, lets a picker change only the components it shows, and
/// formats back — anything the user didn't touch survives byte-for-byte in
/// meaning.
struct PGTemporal: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case date
        case time(tz: Bool)
        case timestamp(tz: Bool)

        var hasDate: Bool {
            if case .time = self { return false }
            return true
        }
        var hasTime: Bool { self != .date }
        var hasZone: Bool {
            switch self {
            case .date: return false
            case .time(let tz), .timestamp(let tz): return tz
            }
        }

        static func from(typeName: String) -> Kind? {
            var t = typeName.lowercased().trimmingCharacters(in: .whitespaces)
            if let paren = t.firstIndex(of: "(") {
                let close = t[paren...].firstIndex(of: ")") ?? t.index(before: t.endIndex)
                t = (String(t[..<paren]) + String(t[t.index(after: close)...]))
                    .trimmingCharacters(in: .whitespaces)
            }
            switch t {
            case "date": return .date
            case "time", "time without time zone": return .time(tz: false)
            case "timetz", "time with time zone": return .time(tz: true)
            case "timestamp", "timestamp without time zone": return .timestamp(tz: false)
            case "timestamptz", "timestamp with time zone": return .timestamp(tz: true)
            default: return nil
            }
        }
    }

    enum Special: Equatable, Sendable { case infinity, negativeInfinity }

    var special: Special?
    var year = 2000
    var month = 1
    var day = 1
    var hour = 0
    var minute = 0
    var second = 0
    var microsecond = 0
    /// Seconds east of UTC, when the text carried an offset.
    var offsetSeconds: Int?
    var isBC = false

    // MARK: - Parsing

    static func parse(_ raw: String, kind: Kind) -> PGTemporal? {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if kind.hasDate {
            if lower == "infinity" || lower == "+infinity" { return PGTemporal(special: .infinity) }
            if lower == "-infinity" { return PGTemporal(special: .negativeInfinity) }
        }
        var value = PGTemporal()
        if kind.hasDate {
            if lower.hasSuffix(" bc") {
                value.isBC = true
                s = s.dropLast(3)
            } else if lower.hasSuffix(" ad") {
                s = s.dropLast(3)
            }
        }
        var scanner = Scan(s)
        if kind.hasDate {
            guard let y = scanner.digits(min: 1, max: 7), scanner.eat("-"),
                  let m = scanner.digits(min: 1, max: 2), scanner.eat("-"),
                  let d = scanner.digits(min: 1, max: 2),
                  (1...12).contains(m), (1...31).contains(d), y >= 1 || value.isBC
            else { return nil }
            value.year = y; value.month = m; value.day = d
            if kind == .date { return scanner.atEnd ? value : nil }
            if scanner.atEnd { return value }
            guard scanner.eat(" ") || scanner.eat("T") || scanner.eat("t") else { return nil }
            scanner.skipSpaces()
        }
        guard let h = scanner.digits(min: 1, max: 2), scanner.eat(":"),
              let mi = scanner.digits(min: 2, max: 2),
              h <= 24, mi <= 59
        else { return nil }
        value.hour = h; value.minute = mi
        if scanner.eat(":") {
            guard let sec = scanner.digits(min: 2, max: 2), sec <= 60 else { return nil }
            value.second = sec
            if scanner.eat(".") {
                guard let frac = scanner.digitString(min: 1, max: 9) else { return nil }
                let six = String((frac + "000000").prefix(6))
                value.microsecond = Int(six) ?? 0
            }
        }
        scanner.skipSpaces()
        if scanner.atEnd { return value }
        if scanner.eat("Z") || scanner.eat("z") {
            value.offsetSeconds = 0
            return scanner.atEnd ? value : nil
        }
        guard let sign = scanner.sign(),
              let oh = scanner.digits(min: 1, max: 2), oh <= 15
        else { return nil }
        var total = oh * 3600
        if scanner.eat(":") || scanner.peekDigit {
            guard let om = scanner.digits(min: 2, max: 2), om <= 59 else { return nil }
            total += om * 60
            if scanner.eat(":") || scanner.peekDigit {
                guard let os = scanner.digits(min: 2, max: 2), os <= 59 else { return nil }
                total += os
            }
        }
        value.offsetSeconds = sign * total
        return scanner.atEnd ? value : nil
    }

    // MARK: - Formatting

    /// ISO text in the shape Postgres itself prints: trailing fractional
    /// zeros trimmed, offsets as `+01`, `+05:30` or `+00:53:28`.
    func format(kind: Kind) -> String {
        if let special {
            return special == .infinity ? "infinity" : "-infinity"
        }
        var out = ""
        if kind.hasDate {
            out += Self.pad(year, 4) + "-" + Self.pad(month, 2) + "-" + Self.pad(day, 2)
        }
        if kind.hasTime {
            if !out.isEmpty { out += " " }
            out += Self.pad(hour, 2) + ":" + Self.pad(minute, 2) + ":" + Self.pad(second, 2)
            if microsecond > 0 {
                var frac = Self.pad(microsecond, 6)
                while frac.hasSuffix("0") { frac.removeLast() }
                out += "." + frac
            }
            if let offsetSeconds {
                out += Self.formatOffset(offsetSeconds)
            }
        }
        if isBC && kind.hasDate { out += " BC" }
        return out
    }

    static func formatOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let a = abs(seconds)
        let h = a / 3600, m = (a % 3600) / 60, s = a % 60
        var out = sign + pad(h, 2)
        if m != 0 || s != 0 { out += ":" + pad(m, 2) }
        if s != 0 { out += ":" + pad(s, 2) }
        return out
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    // MARK: - Picker bridge

    /// The zone a picker should display this value in: its own offset when
    /// it has one, UTC otherwise — never the Mac's local zone, which would
    /// silently shift wall-clock values across DST.
    var pickerTimeZone: TimeZone {
        TimeZone(secondsFromGMT: offsetSeconds ?? 0) ?? TimeZone(identifier: "UTC")!
    }

    private func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pickerTimeZone
        return cal
    }

    /// A `Date` for a picker, or nil when the value can't be shown in one
    /// (±infinity, BC).
    func pickerDate(kind: Kind) -> Date? {
        guard special == nil, !isBC else { return nil }
        var c = DateComponents()
        c.year = kind.hasDate ? year : 2000
        c.month = kind.hasDate ? month : 1
        c.day = kind.hasDate ? day : 1
        c.hour = kind.hasTime ? min(hour, 23) : 0
        c.minute = kind.hasTime ? minute : 0
        c.second = 0
        return calendar().date(from: c)
    }

    /// Take the components a picker shows (date and/or hour:minute) from
    /// `date`, keep everything else — seconds, microseconds, offset.
    func merging(pickerDate date: Date, kind: Kind) -> PGTemporal {
        var out = self
        out.special = nil
        out.isBC = false
        let c = calendar().dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if kind.hasDate {
            out.year = c.year ?? year
            out.month = c.month ?? month
            out.day = c.day ?? day
        }
        if kind.hasTime {
            out.hour = c.hour ?? hour
            out.minute = c.minute ?? minute
        }
        return out
    }

    /// Fresh value for an empty field: local wall-clock now, with the local
    /// offset spelled out for zone-aware kinds.
    static func now(kind: Kind, at date: Date = Date(), zone: TimeZone = .current) -> PGTemporal {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var v = PGTemporal()
        v.year = c.year ?? 2000; v.month = c.month ?? 1; v.day = c.day ?? 1
        v.hour = c.hour ?? 0; v.minute = c.minute ?? 0; v.second = c.second ?? 0
        if kind.hasZone { v.offsetSeconds = zone.secondsFromGMT(for: date) }
        return v
    }

    // MARK: - Scanner

    private struct Scan {
        var chars: [Character]
        var i = 0
        init(_ s: Substring) { chars = Array(s) }

        var atEnd: Bool { i >= chars.count }
        var peekDigit: Bool { !atEnd && chars[i].isASCII && chars[i].isNumber }

        mutating func eat(_ c: Character) -> Bool {
            guard !atEnd, chars[i] == c else { return false }
            i += 1
            return true
        }

        mutating func skipSpaces() {
            while !atEnd, chars[i] == " " { i += 1 }
        }

        mutating func sign() -> Int? {
            if eat("+") { return 1 }
            if eat("-") { return -1 }
            return nil
        }

        mutating func digitString(min: Int, max: Int) -> String? {
            var s = ""
            while peekDigit, s.count < max { s.append(chars[i]); i += 1 }
            return s.count >= min ? s : nil
        }

        mutating func digits(min: Int, max: Int) -> Int? {
            digitString(min: min, max: max).flatMap { Int($0) }
        }
    }
}
