import Foundation
import Testing
@testable import ThreadKeep

/// Pure-logic tests for the Wi-Fi sync wire framing (protocol v1): the
/// 4-byte big-endian length prefix, single-Data frame encoding, and the
/// incremental decoder's tolerance for short reads and coalesced frames.
struct WiFiSyncFramingTests {
    @Test
    func encodedFrameHasBigEndianLengthPrefix() {
        let payload = Data("hello".utf8)
        let frame = WiFiSyncFraming.encodeFrame(payload)

        #expect(frame.count == 4 + payload.count)
        #expect(Array(frame.prefix(4)) == [0, 0, 0, 5])
        #expect(frame.dropFirst(4) == payload)
    }

    @Test
    func encodedEmptyPayloadIsJustTheHeader() {
        let frame = WiFiSyncFraming.encodeFrame(Data())
        #expect(Array(frame) == [0, 0, 0, 0])
    }

    @Test
    func largeLengthEncodesAcrossAllFourBytes() {
        // 0x01020304 bytes would be a huge payload; just verify header math
        // on a length that exercises every byte of the prefix.
        let payload = Data(count: 0x0001_0203)
        let frame = WiFiSyncFraming.encodeFrame(payload)
        #expect(Array(frame.prefix(4)) == [0x00, 0x01, 0x02, 0x03])
    }

    @Test
    func decoderRoundTripsASingleFrame() throws {
        var decoder = WiFiSyncFrameDecoder()
        let payload = Data("{\"t\":\"hello\",\"v\":1}".utf8)
        decoder.append(WiFiSyncFraming.encodeFrame(payload))

        #expect(try decoder.nextFrame() == payload)
        #expect(try decoder.nextFrame() == nil)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test
    func decoderHandlesOneByteAtATime() throws {
        var decoder = WiFiSyncFrameDecoder()
        let payload = Data("short reads happen".utf8)
        let frame = WiFiSyncFraming.encodeFrame(payload)

        for (index, byte) in frame.enumerated() {
            decoder.append(Data([byte]))
            if index < frame.count - 1 {
                #expect(try decoder.nextFrame() == nil)
            }
        }

        #expect(try decoder.nextFrame() == payload)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test
    func decoderHandlesMultipleFramesInOneChunk() throws {
        var decoder = WiFiSyncFrameDecoder()
        let first = Data("first".utf8)
        let second = Data("second, a bit longer".utf8)
        let third = Data()

        var chunk = WiFiSyncFraming.encodeFrame(first)
        chunk.append(WiFiSyncFraming.encodeFrame(second))
        chunk.append(WiFiSyncFraming.encodeFrame(third))
        decoder.append(chunk)

        #expect(try decoder.nextFrame() == first)
        #expect(try decoder.nextFrame() == second)
        #expect(try decoder.nextFrame() == third)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test
    func decoderHandlesFrameSplitAcrossChunkBoundary() throws {
        var decoder = WiFiSyncFrameDecoder()
        let first = Data("alpha".utf8)
        let second = Data("beta".utf8)

        var wire = WiFiSyncFraming.encodeFrame(first)
        wire.append(WiFiSyncFraming.encodeFrame(second))

        // Split mid-way through the second frame's payload.
        let splitPoint = wire.count - 2
        decoder.append(Data(wire.prefix(splitPoint)))
        #expect(try decoder.nextFrame() == first)
        #expect(try decoder.nextFrame() == nil)

        decoder.append(Data(wire.suffix(2)))
        #expect(try decoder.nextFrame() == second)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test
    func decoderRejectsImplausiblyLargeHeader() {
        var decoder = WiFiSyncFrameDecoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        #expect(throws: WiFiSyncFrameDecoder.DecodeError.payloadTooLarge(declaredLength: 0xFFFF_FFFF)) {
            _ = try decoder.nextFrame()
        }
    }

    @Test
    func decoderSurvivesBinaryPayloadBytes() throws {
        var decoder = WiFiSyncFrameDecoder()
        let payload = Data((0...255).map { UInt8($0) })
        decoder.append(WiFiSyncFraming.encodeFrame(payload))
        #expect(try decoder.nextFrame() == payload)
    }

    @Test
    func displayTitlePrettifiesSuggestedFilenames() {
        #expect(
            ThreadKeepWiFiSyncEngine.displayTitle(forSuggestedFilename: "ThreadKeep-nancy-glimcher.threadkeeparchive")
                == "Nancy Glimcher"
        )
        #expect(
            ThreadKeepWiFiSyncEngine.displayTitle(forSuggestedFilename: "ThreadKeep-.threadkeeparchive")
                == "Conversation"
        )
    }
}
