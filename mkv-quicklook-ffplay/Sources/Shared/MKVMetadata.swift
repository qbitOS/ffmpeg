import Foundation

/// Simple pure-Swift Matroska (MKV/MKA) metadata extractor.
/// Focus: Duration + basic track list (codec, type, language, name).
/// No dependency on ffprobe. Good fallback when exec is blocked or for instant info.
public struct MKVMetadata: Equatable {
    public var filename: String
    public var fileSize: Int64
    public var duration: TimeInterval?   // seconds
    public var title: String?
    public var tracks: [Track]

    public struct Track: Equatable, Identifiable {
        public var id: Int
        public var type: TrackType
        public var codecID: String
        public var name: String?
        public var language: String?
        public var defaultTrack: Bool

        public enum TrackType: String, Equatable {
            case video, audio, subtitle, other
        }
    }

    public var formattedDuration: String {
        guard let d = duration else { return "unknown" }
        let h = Int(d) / 3600
        let m = (Int(d) % 3600) / 60
        let s = Int(d) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    public var summary: String {
        var parts: [String] = []
        if duration != nil { parts.append(formattedDuration) }
        let v = tracks.filter { $0.type == .video }.count
        let a = tracks.filter { $0.type == .audio }.count
        if v > 0 { parts.append("\(v) video") }
        if a > 0 { parts.append("\(a) audio") }
        if tracks.count > v + a { parts.append("\(tracks.count - v - a) subs/other") }
        return parts.joined(separator: " · ")
    }
}

public enum MKVParseError: Error {
    case notMatroska
    case ioError
    case truncated
}

/// Minimal EBML/MKV parser. Walks the element tree just enough to find:
/// - Segment/Info/Duration + TimestampScale
/// - Segment/Tracks/TrackEntry[]
public func parseMKVMetadata(at url: URL) throws -> MKVMetadata {
    let data = try Data(contentsOf: url, options: [.alwaysMapped])
    guard data.count > 4 else { throw MKVParseError.truncated }

    // EBML header must start with 0x1A 45 DF A3
    guard data.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) else {
        throw MKVParseError.notMatroska
    }

    var parser = MKVParser(data: data)
    guard let root = try parser.parseElement() else {
        throw MKVParseError.truncated
    }

    // Root should be EBML then Segment. We look inside for Segment.
    var segment: MKVElement?
    if root.id == 0x1A45DFA3 { // EBML
        // next sibling or contained is usually Segment at top level
        // Re-parse looking for Segment (0x18538067)
        parser = MKVParser(data: data)
        _ = try parser.parseElement() // skip EBML
        segment = try parser.parseElement()
    } else if root.id == 0x18538067 {
        segment = root
    }

    guard let seg = segment, seg.id == 0x18538067 else {
        throw MKVParseError.notMatroska
    }

    var duration: TimeInterval?
    var title: String?
    var tracks: [MKVMetadata.Track] = []
    var timecodeScale: UInt64 = 1_000_000 // default

    // Walk children of Segment
    var segParser = MKVParser(data: seg.data)
    while let child = try segParser.parseElement() {
        switch child.id {
        case 0x1549A966: // Info
            var infoParser = MKVParser(data: child.data)
            while let infoChild = try infoParser.parseElement() {
                switch infoChild.id {
                case 0x2AD7B1: // TimestampScale
                    timecodeScale = infoChild.asUInt() ?? timecodeScale
                case 0x4489: // Duration (float)
                    if let f = infoChild.asDouble() {
                        duration = f * Double(timecodeScale) / 1_000_000_000.0
                    }
                case 0x7BA9: // Title
                    title = infoChild.asString()
                default:
                    break
                }
            }
        case 0x1654AE6B: // Tracks
            var tracksParser = MKVParser(data: child.data)
            while let trackContainer = try tracksParser.parseElement() {
                if trackContainer.id == 0xAE { // TrackEntry
                    if let tr = parseTrackEntry(trackContainer.data) {
                        tracks.append(tr)
                    }
                }
            }
        default:
            break
        }
    }

    let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .nameKey])
    let size = attrs?.fileSize.map(Int64.init) ?? 0
    let name = attrs?.name ?? url.lastPathComponent

    return MKVMetadata(
        filename: name,
        fileSize: size,
        duration: duration,
        title: title,
        tracks: tracks
    )
}

// MARK: - Track parsing

private func parseTrackEntry(_ data: Data) -> MKVMetadata.Track? {
    var p = MKVParser(data: data)
    var trackNum: Int?
    var trackTypeRaw: UInt64?
    var codecID: String?
    var name: String?
    var lang: String?
    var isDefault = true

    while let el = try? p.parseElement() {
        switch el.id {
        case 0xD7: // TrackNumber
            trackNum = Int(el.asUInt() ?? 0)
        case 0x83: // TrackType
            trackTypeRaw = el.asUInt()
        case 0x86: // CodecID
            codecID = el.asString()
        case 0x536E: // Name
            name = el.asString()
        case 0x22B59C: // Language (IETF in newer, but also legacy 0x22B59C? wait standard is 0x22B59C for LanguageBCP47? check common)
            lang = el.asString()
        case 0x9C: // FlagDefault
            isDefault = (el.asUInt() ?? 1) != 0
        case 0x6D80: // ContentEncodings (skip)
            break
        default:
            break
        }
    }

    guard let tnum = trackNum, let c = codecID, let ttype = trackTypeRaw else { return nil }

    let type: MKVMetadata.Track.TrackType
    switch ttype {
    case 1: type = .video
    case 2: type = .audio
    case 3: type = .subtitle
    default: type = .other
    }

    return MKVMetadata.Track(
        id: tnum,
        type: type,
        codecID: c,
        name: name,
        language: lang,
        defaultTrack: isDefault
    )
}

// MARK: - Low level EBML parser

private struct MKVElement {
    let id: UInt32
    let data: Data   // the payload only
}

private struct MKVParser {
    let data: Data
    var offset: Int = 0

    mutating func parseElement() throws -> MKVElement? {
        guard offset < data.count else { return nil }

        // Read Element ID (variable length, the "length descriptor" bits are part of the ID value for matching)
        guard let idLen = ebmlLength(at: offset) else { throw MKVParseError.truncated }
        guard idLen >= 1 && idLen <= 4 else { throw MKVParseError.truncated }
        _ = readUIntNoAdvance(bytes: idLen)  // peek (we only need the consumed value)
        // actually consume
        let idVal = readUInt(bytes: idLen)

        // Read size descriptor
        guard let sizeLen = ebmlLength(at: offset) else { throw MKVParseError.truncated }
        let sizeValRaw = readUIntNoAdvance(bytes: sizeLen)
        let sizeLenBytes = sizeLen
        _ = readUInt(bytes: sizeLenBytes) // consume the bytes for offset

        // Mask the size (the leading 1 bit in the first byte of the size field indicates the width, the rest is the value)
        let sizeMask: UInt64 = (1 << (7 * sizeLen)) - 1
        let size = sizeValRaw & sizeMask

        guard offset + Int(size) <= data.count else {
            // Some files legitimately have "unknown size" (all 1s after mask) for the last element (Segment).
            // For safety we stop instead of crashing.
            return nil
        }

        let payload = data.subdata(in: offset..<offset + Int(size))
        offset += Int(size)

        return MKVElement(id: UInt32(idVal), data: payload)
    }

    private func ebmlLength(at pos: Int) -> Int? {
        guard pos < data.count else { return nil }
        let first = data[pos]
        if first & 0x80 != 0 { return 1 }
        if first & 0x40 != 0 { return 2 }
        if first & 0x20 != 0 { return 3 }
        if first & 0x10 != 0 { return 4 }
        if first & 0x08 != 0 { return 5 }
        if first & 0x04 != 0 { return 6 }
        if first & 0x02 != 0 { return 7 }
        if first & 0x01 != 0 { return 8 }
        return nil
    }

    private mutating func readUInt(bytes: Int) -> UInt64 {
        var val: UInt64 = 0
        for _ in 0..<bytes {
            val = (val << 8) | UInt64(data[offset])
            offset += 1
        }
        return val
    }

    // Peek version that does not advance offset (for deciding + masking)
    private func readUIntNoAdvance(bytes: Int) -> UInt64 {
        var val: UInt64 = 0
        var pos = offset
        for _ in 0..<bytes {
            val = (val << 8) | UInt64(data[pos])
            pos += 1
        }
        return val
    }
}

private extension MKVElement {
    func asUInt() -> UInt64? {
        // Big endian integer of any length up to 8
        guard data.count <= 8 else { return nil }
        var v: UInt64 = 0
        for b in data { v = (v << 8) | UInt64(b) }
        return v
    }

    func asDouble() -> Double? {
        guard data.count == 4 || data.count == 8 else { return nil }
        if data.count == 4 {
            let bits = UInt32(bigEndian: data.withUnsafeBytes { $0.load(as: UInt32.self) })
            return Double(Float(bitPattern: bits))
        } else {
            let bits = UInt64(bigEndian: data.withUnsafeBytes { $0.load(as: UInt64.self) })
            return Double(bitPattern: bits)
        }
    }

    func asString() -> String? {
        String(data: data, encoding: .utf8)
    }
}
