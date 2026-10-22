import CoreGraphics
import Foundation

/// One encoded picture of a `capture.stream`, sent as a binary WebSocket
/// message on the same socket as the JSON envelope. Mac and Linux hosts both
/// write this; the viewer reads it.
///
/// Layout, big-endian, 48-byte header then payload:
///
///     0   "LVF1"
///     4   streamId   u32
///     8   seq        u32   per stream, from 1
///     12  flags      u8    bit0 keyframe, bit1 parameter sets follow
///     13  codec      u8    1 h264, 2 hevc
///     14  reserved   u16
///     16  pts        u64   microseconds, host clock
///     24  width      u32   coded picture
///     28  height     u32
///     32  frame      4×f32 x, y, w, h: the host-space rect the picture shows
///     48  [parameter sets: u16 count, then u16 length + bytes each]
///         access unit: NAL units, each with a u32 length prefix (AVCC)
struct RemoteVideoFrame: Equatable {
    enum Codec: UInt8 {
        case h264 = 1
        case hevc = 2
    }

    static let magic: [UInt8] = Array("LVF1".utf8)
    static let headerSize = 48

    var streamID: UInt32
    var seq: UInt32
    var keyframe: Bool
    var codec: Codec
    var pts: UInt64
    var width: UInt32
    var height: UInt32
    var frame: CGRect
    /// SPS and PPS (and VPS for HEVC), on keyframes.
    var parameterSets: [Data]
    /// Length-prefixed NAL units.
    var accessUnit: Data

    func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + accessUnit.count + parameterSets.reduce(2) { $0 + 2 + $1.count })
        out.append(contentsOf: Self.magic)
        out.appendBig(streamID)
        out.appendBig(seq)
        out.append((keyframe ? 1 : 0) | (parameterSets.isEmpty ? 0 : 2))
        out.append(codec.rawValue)
        out.appendBig(UInt16(0))
        out.appendBig(pts)
        out.appendBig(width)
        out.appendBig(height)
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            out.appendBig(Float32(value).bitPattern)
        }
        if !parameterSets.isEmpty {
            out.appendBig(UInt16(parameterSets.count))
            for set in parameterSets {
                out.appendBig(UInt16(set.count))
                out.append(set)
            }
        }
        out.append(accessUnit)
        return out
    }

    init(streamID: UInt32, seq: UInt32, keyframe: Bool, codec: Codec, pts: UInt64, width: UInt32, height: UInt32,
         frame: CGRect, parameterSets: [Data], accessUnit: Data) {
        self.streamID = streamID
        self.seq = seq
        self.keyframe = keyframe
        self.codec = codec
        self.pts = pts
        self.width = width
        self.height = height
        self.frame = frame
        self.parameterSets = parameterSets
        self.accessUnit = accessUnit
    }

    /// Nil for anything that isn't a whole, well-formed frame.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize, Array(bytes[0..<4]) == Self.magic,
              let codec = Codec(rawValue: bytes[13]) else { return nil }
        var reader = BigEndianReader(bytes: bytes, offset: 4)
        streamID = reader.u32()
        seq = reader.u32()
        let flags = reader.u8()
        _ = reader.u8()
        _ = reader.u16()
        self.codec = codec
        keyframe = flags & 1 != 0
        pts = reader.u64()
        width = reader.u32()
        height = reader.u32()
        let x = Float32(bitPattern: reader.u32()), y = Float32(bitPattern: reader.u32())
        let w = Float32(bitPattern: reader.u32()), h = Float32(bitPattern: reader.u32())
        frame = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        var sets: [Data] = []
        if flags & 2 != 0 {
            guard reader.remaining >= 2 else { return nil }
            let count = Int(reader.u16())
            for _ in 0..<count {
                guard reader.remaining >= 2 else { return nil }
                let length = Int(reader.u16())
                guard reader.remaining >= length else { return nil }
                sets.append(reader.data(length))
            }
        }
        parameterSets = sets
        accessUnit = reader.data(reader.remaining)
    }

    /// Splits an Annex B byte stream (00 00 01 / 00 00 00 01 start codes)
    /// into NAL unit payloads.
    static func nalUnits(annexB data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = i > 0 && bytes[i - 1] == 0 ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].code : bytes.count
            return end > start.payload ? Data(bytes[start.payload..<end]) : nil
        }
    }

    /// NAL units with a u32 big-endian length before each.
    static func lengthPrefixed(_ units: [Data]) -> Data {
        var out = Data()
        for unit in units {
            out.appendBig(UInt32(unit.count))
            out.append(unit)
        }
        return out
    }
}

private struct BigEndianReader {
    let bytes: [UInt8]
    var offset: Int

    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8 {
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() -> UInt16 { UInt16(read(2)) }
    mutating func u32() -> UInt32 { UInt32(read(4)) }
    mutating func u64() -> UInt64 { read(8) }

    mutating func data(_ count: Int) -> Data {
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    private mutating func read(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count { value = value << 8 | UInt64(u8()) }
        return value
    }
}

private extension Data {
    mutating func appendBig<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
