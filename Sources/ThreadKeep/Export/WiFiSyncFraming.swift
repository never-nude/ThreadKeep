import Foundation

/// Length-prefixed framing for the ThreadKeep Wi-Fi sync wire protocol (v1).
///
/// Every frame on the wire is a 4-byte big-endian UInt32 payload length
/// followed by exactly that many payload bytes. Control frames carry UTF-8
/// JSON objects with a "t" key; archive payload frames carry the raw JSON
/// bytes of one archive.
///
/// This type is pure Foundation so it can be unit-tested on any platform.
enum WiFiSyncFraming {
    static let headerLength = 4

    /// Upper bound on a single frame's payload, as a sanity check against
    /// garbage headers from a misbehaving peer (512 MiB).
    static let maximumPayloadLength: UInt32 = 512 * 1024 * 1024

    /// Encodes one complete frame (header + payload) as a single Data value,
    /// so callers can hand the whole frame to one send call.
    static func encodeFrame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        var frame = Data(capacity: headerLength + payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(payload)
        return frame
    }
}

/// Incremental decoder for length-prefixed frames.
///
/// Feed it arbitrary chunks as they arrive from the network (short reads are
/// fine), then drain complete frames with `nextFrame()` until it returns nil.
struct WiFiSyncFrameDecoder {
    enum DecodeError: Error, Equatable {
        case payloadTooLarge(declaredLength: UInt32)
    }

    private var buffer = Data()

    /// Bytes currently buffered and not yet consumed as frames.
    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// Returns the next complete frame's payload, or nil if more bytes are
    /// needed. Throws if a header declares an implausibly large payload.
    mutating func nextFrame() throws -> Data? {
        guard buffer.count >= WiFiSyncFraming.headerLength else { return nil }

        let start = buffer.startIndex
        var declaredLength: UInt32 = 0
        for offset in 0..<WiFiSyncFraming.headerLength {
            let byte = buffer[buffer.index(start, offsetBy: offset)]
            declaredLength = (declaredLength << 8) | UInt32(byte)
        }

        guard declaredLength <= WiFiSyncFraming.maximumPayloadLength else {
            throw DecodeError.payloadTooLarge(declaredLength: declaredLength)
        }

        let totalFrameLength = WiFiSyncFraming.headerLength + Int(declaredLength)
        guard buffer.count >= totalFrameLength else { return nil }

        let payloadStart = buffer.index(start, offsetBy: WiFiSyncFraming.headerLength)
        let frameEnd = buffer.index(start, offsetBy: totalFrameLength)
        let payload = Data(buffer[payloadStart..<frameEnd])
        buffer = Data(buffer[frameEnd...])
        return payload
    }
}
