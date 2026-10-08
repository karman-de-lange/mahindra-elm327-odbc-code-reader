import Foundation

/// Turns ELM327 text into fault codes, lamp status, and VIN.
///
/// Scorpio S11 answers on 11-bit CAN. With headers on, a line looks like
/// `7E8 06 43 01 33 00 00 00`: the CAN id, a length byte, then the payload.
/// Clones sometimes leave ISO-TP framing in place, or print the ELM multiline
/// form that starts with a 3-digit byte count. Both are accepted.
public enum ObdResponse {
    public static func parseFaults(response: String, status: FaultStatus) -> FaultRead {
        let upper = normalized(response)
        let linkFailed = isLinkFailure(upper)
        var rejected: [String] = []
        var codes: [FaultCode] = []
        var sawList = false
        let service = serviceByte(for: status)

        for frame in frames(in: upper) {
            guard let first = frame.bytes.first else { continue }
            if first == 0x7F {
                let nrc = frame.bytes.count >= 3 ? frame.bytes[2] : 0
                rejected.append("\(moduleName(for: frame.header)) rejected the request (\(nrcName(nrc))).")
                continue
            }
            guard first == service else { continue }
            sawList = true
            var index = 1
            while index + 1 < frame.bytes.count {
                let raw = UInt16(frame.bytes[index]) << 8 | UInt16(frame.bytes[index + 1])
                index += 2
                if raw == 0 { continue }
                let code = format(raw: raw)
                let fault = FaultCode(
                    code: code,
                    status: status,
                    moduleID: frame.header,
                    moduleName: moduleName(for: frame.header),
                    summary: FaultCatalog.summary(for: code),
                    detail: ""
                )
                if !codes.contains(where: { $0.id == fault.id }) {
                    codes.append(fault)
                }
            }
        }

        let noData = codes.isEmpty && !linkFailed && rejected.isEmpty && (upper.contains("NO DATA") || sawList)
        return FaultRead(codes: codes, noData: noData, linkFailed: linkFailed, rejected: rejected)
    }

    public static func parseMonitor(response: String) -> MonitorStatus? {
        let list = frames(in: normalized(response))
        let preferred = list.first(where: { $0.header == "7E8" && isMonitor($0.bytes) })
            ?? list.first(where: { isMonitor($0.bytes) })
        guard let bytes = preferred?.bytes else { return nil }
        let status = bytes[2]
        return MonitorStatus(milOn: (status & 0x80) != 0, storedCodeCount: Int(status & 0x7F))
    }

    public static func answeredSupportedPIDs(_ response: String) -> Bool {
        frames(in: normalized(response)).contains { frame in
            frame.bytes.count >= 2 && frame.bytes[0] == 0x41 && frame.bytes[1] == 0x00
        }
    }

    public static func didClear(_ response: String) -> Bool {
        frames(in: normalized(response)).contains { $0.bytes.first == 0x44 }
    }

    /// Service 14, all groups. A `54` means the factory list accepted the erase.
    public static func didClearHistory(_ response: String) -> Bool {
        frames(in: normalized(response)).contains { $0.bytes.first == 0x54 }
    }

    public static func parseVIN(_ response: String) -> String? {
        var chars: [Character] = []
        for frame in frames(in: normalized(response)) {
            let bytes = frame.bytes
            var index = 0
            while index + 2 < bytes.count {
                if bytes[index] == 0x49 && bytes[index + 1] == 0x02 {
                    index += 3
                    while index < bytes.count {
                        let byte = bytes[index]
                        if byte == 0 { break }
                        guard let scalar = UnicodeScalar(UInt32(byte)) else { break }
                        let character = Character(scalar)
                        if character.isLetter || character.isNumber {
                            chars.append(character)
                        } else {
                            break
                        }
                        index += 1
                    }
                } else {
                    index += 1
                }
            }
        }
        guard chars.count >= 17 else { return nil }
        return String(chars.prefix(17))
    }

    public static func parseVoltage(_ response: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2}\.\d)\s*V"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(response.startIndex..., in: response)
        guard let match = regex.firstMatch(in: response, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: response) else {
            return nil
        }
        return "\(response[valueRange]) V"
    }

    public static func format(raw: UInt16) -> String {
        let hi = Int((raw >> 8) & 0xFF)
        let lo = Int(raw & 0xFF)
        let systems = ["P", "C", "B", "U"]
        let system = systems[(hi >> 6) & 0x3]
        let second = (hi >> 4) & 0x3
        let third = hi & 0x0F
        return String(format: "%@%d%X%02X", system, second, third, lo)
    }

    public static func moduleName(for header: String?) -> String {
        switch header?.uppercased() {
        case "7E8": return "Engine"
        case "7E9": return "Transmission"
        case nil: return "ECU"
        case let other?: return "Module \(other)"
        }
    }

    private struct Frame {
        var header: String?
        var bytes: [UInt8]
    }

    private struct Piece {
        var header: String?
        var bytes: [UInt8]
    }

    private static func serviceByte(for status: FaultStatus) -> UInt8 {
        switch status {
        case .stored: return 0x43
        case .pending: return 0x47
        case .permanent: return 0x4A
        case .history: return 0x59
        }
    }

    /// Mahindra keeps lamp history on UDS service 19, not in mode 03.
    /// A 59 02 payload is the status mask, then 4-byte records: code, fault type, status.
    /// A 58 payload is the older KWP list: a count, then 3-byte records.
    public static func parseHistory(response: String) -> FaultRead {
        let upper = normalized(response)
        let linkFailed = isLinkFailure(upper)
        var rejected: [String] = []
        var codes: [FaultCode] = []
        var sawList = false

        for frame in frames(in: upper) {
            let bytes = frame.bytes
            guard let first = bytes.first else { continue }
            if first == 0x7F {
                let nrc = bytes.count >= 3 ? bytes[2] : 0
                rejected.append("\(moduleName(for: frame.header)) rejected the request (\(nrcName(nrc))).")
                continue
            }
            if first == 0x59, bytes.count >= 3, bytes[1] == 0x02 || isSingleConfirmed(bytes[1]) {
                sawList = true
                var index = 3
                if isSingleConfirmed(bytes[1]) {
                    let rest = bytes.count - 2
                    if rest % 4 != 0, (rest - 1) % 4 == 0 { index = 3 }
                    else { index = 2 }
                }
                while index + 3 < bytes.count {
                    let raw = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
                    let failureType = bytes[index + 2]
                    let statusBits = bytes[index + 3]
                    index += 4
                    guard raw != 0 else { continue }
                    codes.append(historyCode(raw: raw, failureType: failureType, statusBits: statusBits, header: frame.header))
                }
            } else if first == 0x58, bytes.count >= 4 {
                sawList = true
                let count = Int(bytes[1])
                var index = 2
                var found = 0
                while index + 2 < bytes.count, found < max(count, 1) || (count == 0 && index + 2 < bytes.count) {
                    if count > 0 && found >= count { break }
                    let raw = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
                    let statusBits = bytes[index + 2]
                    index += 3
                    found += 1
                    guard raw != 0 else { continue }
                    codes.append(historyCode(raw: raw, failureType: 0, statusBits: statusBits, header: frame.header))
                }
            }
        }

        var unique: [FaultCode] = []
        for code in codes where !unique.contains(where: { $0.id == code.id }) {
            unique.append(code)
        }
        let noData = unique.isEmpty && !linkFailed && rejected.isEmpty && (upper.contains("NO DATA") || sawList)
        return FaultRead(codes: unique, noData: noData, linkFailed: linkFailed, rejected: rejected)
    }

    /// 19 0B / 0C / 0D / 0E return one confirmed code. Mode 03 never lists these.
    private static func isSingleConfirmed(_ subfunction: UInt8) -> Bool {
        (0x0B...0x0E).contains(subfunction)
    }

    private static func historyCode(raw: UInt16, failureType: UInt8, statusBits: UInt8, header: String?) -> FaultCode {
        var code = format(raw: raw)
        if failureType != 0 {
            code += String(format: "-%02X", failureType)
        }
        let base = String(code.prefix(5))
        return FaultCode(
            code: code,
            status: .history,
            moduleID: header,
            moduleName: moduleName(for: header),
            summary: FaultCatalog.summary(for: base),
            detail: historyDetail(statusBits: statusBits, failureType: failureType)
        )
    }

    private static func historyDetail(statusBits: UInt8, failureType: UInt8) -> String {
        var parts: [String] = []
        if statusBits & 0x80 != 0 { parts.append("Lamp on") }
        if statusBits & 0x01 != 0 { parts.append("Failing now") }
        if statusBits & 0x08 != 0 { parts.append("Confirmed") }
        if statusBits & 0x04 != 0 { parts.append("Pending") }
        if statusBits & 0x20 != 0 { parts.append("Failed since last clear") }
        if statusBits & 0x02 != 0 { parts.append("Failed this drive") }
        if parts.isEmpty { parts.append("Recorded earlier") }
        var text = parts.joined(separator: ". ")
        if failureType != 0 {
            text += String(format: ". Fault type %02X", failureType)
        }
        return text + "."
    }

    private static func isMonitor(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[0] == 0x41 && bytes[1] == 0x01
    }

    private static func normalized(_ response: String) -> String {
        response
            .uppercased()
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: ">", with: "\n")
    }

    private static func isLinkFailure(_ upper: String) -> Bool {
        upper.contains("UNABLE TO CONNECT")
            || upper.contains("CAN ERROR")
            || upper.contains("BUS ERROR")
            || upper.contains("BUS INIT: ERROR")
            || upper.contains("BUS INIT: BUSY")
            || upper.contains("BUS BUSY")
    }

    private static func frames(in upper: String) -> [Frame] {
        let parts = pieces(in: upper)
        var result: [Frame] = []
        var index = 0
        while index < parts.count {
            let piece = parts[index]
            if let pci = piece.bytes.first, (pci & 0xF0) == 0x10, piece.bytes.count >= 2 {
                let total = (Int(pci & 0x0F) << 8) | Int(piece.bytes[1])
                var merged = Array(piece.bytes.dropFirst(2))
                var next = index + 1
                while next < parts.count, parts[next].header == piece.header {
                    let chunk = parts[next].bytes
                    guard let marker = chunk.first, (marker & 0xF0) == 0x20 else { break }
                    merged.append(contentsOf: chunk.dropFirst())
                    next += 1
                    if total > 0, merged.count >= total { break }
                }
                let payload = total > 0 && total <= merged.count ? Array(merged.prefix(total)) : merged
                if !payload.isEmpty {
                    result.append(Frame(header: piece.header, bytes: payload))
                }
                index = next
            } else {
                if !piece.bytes.isEmpty {
                    result.append(Frame(header: piece.header, bytes: piece.bytes))
                }
                index += 1
            }
        }
        return result
    }

    private static func pieces(in upper: String) -> [Piece] {
        var result: [Piece] = []
        var expected: Int?
        var bucket: [UInt8] = []

        func flushBucket() {
            guard !bucket.isEmpty else {
                expected = nil
                return
            }
            var bytes = bucket
            if let expected, bytes.count > expected {
                bytes = Array(bytes.prefix(expected))
            }
            result.append(Piece(header: nil, bytes: prepare(bytes)))
            bucket = []
            expected = nil
        }

        for rawLine in upper.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if isNoise(line) { continue }
            var tokens = hexTokens(line)
            if tokens.isEmpty { continue }
            if tokens.count == 1, tokens[0].count == 3, !isHeader(tokens[0]), let count = Int(tokens[0], radix: 16) {
                flushBucket()
                expected = count
                continue
            }

            var header: String?
            if let first = tokens.first, isHeader(first) {
                header = first
                tokens.removeFirst()
            }
            let bytes = tokens.compactMap { UInt8($0, radix: 16) }
            if bytes.isEmpty { continue }
            if header == nil, expected != nil {
                bucket.append(contentsOf: bytes)
                continue
            }
            flushBucket()
            result.append(Piece(header: header, bytes: prepare(bytes)))
        }
        flushBucket()
        return result
    }

    /// Drops the CAN length byte ELM prints after the header when it matches the payload.
    private static func prepare(_ bytes: [UInt8]) -> [UInt8] {
        guard let first = bytes.first else { return bytes }
        if (first & 0xF0) == 0x10 || (first & 0xF0) == 0x20 {
            return bytes
        }
        return stripLength(bytes)
    }

    private static func stripLength(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count >= 2 else { return bytes }
        let length = Int(bytes[0])
        guard length == bytes.count - 1, isResponseService(bytes[1]) else { return bytes }
        return Array(bytes.dropFirst())
    }

    private static func isResponseService(_ byte: UInt8) -> Bool {
        (0x41...0x4A).contains(byte) || byte == 0x54 || byte == 0x58 || byte == 0x59 || byte == 0x7F
    }

    private static func isHeader(_ token: String) -> Bool {
        if token.count == 3, let value = Int(token, radix: 16) {
            return (0x700...0x7FF).contains(value)
        }
        if token.count == 8 {
            return token.hasPrefix("18DA") || token.hasPrefix("18DB")
        }
        return false
    }

    private static func hexTokens(_ line: String) -> [String] {
        let runs = line.split(whereSeparator: { !$0.isHexDigit }).map(String.init)
        return runs.flatMap(expand).filter { $0.count != 1 && $0.allSatisfy(\.isHexDigit) }
    }

    private static func expand(_ part: String) -> [String] {
        if part.count <= 3 {
            return [part]
        }
        let isExtendedHeader = part.hasPrefix("18DA") || part.hasPrefix("18DB")
        if part.count == 8, isExtendedHeader {
            return [part]
        }
        var body = part
        var tokens: [String] = []
        if part.count > 8, isExtendedHeader {
            tokens.append(String(part.prefix(8)))
            body = String(part.dropFirst(8))
        } else if part.count % 2 == 1 {
            let head = String(part.prefix(3))
            if isHeader(head) {
                tokens.append(head)
                body = String(part.dropFirst(3))
            }
        }
        guard body.count % 2 == 0 else {
            tokens.append(body)
            return tokens
        }
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2)
            tokens.append(String(body[index..<next]))
            index = next
        }
        return tokens
    }

    private static func isNoise(_ line: String) -> Bool {
        if line.isEmpty { return true }
        if line.contains("SEARCHING") || line.contains("ELM") { return true }
        if line == "OK" || line == "NO DATA" || line == "?" { return true }
        if line.hasPrefix("UNABLE") || line.hasPrefix("BUS ") || line.hasPrefix("CAN ERROR") { return true }
        if line.hasPrefix("STOPPED") || line.hasPrefix("ERROR") || line.hasPrefix("AT") { return true }
        let compact = line.replacingOccurrences(of: " ", with: "")
        return ["03", "07", "0A", "04", "0100", "0101", "0902"].contains(compact)
    }

    private static func nrcName(_ nrc: UInt8) -> String {
        switch nrc {
        case 0x10: return "general reject"
        case 0x11: return "service not supported"
        case 0x12: return "sub-function not supported"
        case 0x22: return "conditions not correct"
        case 0x31: return "request out of range"
        case 0x78: return "response pending"
        case 0x7E: return "service not supported in this session"
        default: return String(format: "reason %02X", nrc)
        }
    }
}
