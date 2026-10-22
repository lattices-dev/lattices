import AVFoundation
import CoreMedia
import VideoToolbox
import XCTest
@testable import Lattices

final class RemoteVideoFrameTests: XCTestCase {
    private func sample(seq: UInt32 = 1, keyframe: Bool = true, sets: [Data] = [Data([0x67, 1, 2]), Data([0x68, 3])]) -> RemoteVideoFrame {
        RemoteVideoFrame(streamID: 7, seq: seq, keyframe: keyframe, codec: .h264, pts: 1_234_567_890_123,
                         width: 1920, height: 1080, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                         parameterSets: sets, accessUnit: RemoteVideoFrame.lengthPrefixed([Data([0x65, 9, 9, 9])]))
    }

    func testKeyframeRoundTrips() {
        let frame = sample()
        let data = frame.encoded()
        XCTAssertEqual(Array(data.prefix(4)), Array("LVF1".utf8))
        XCTAssertEqual(data[12], 3)
        XCTAssertEqual(data.count, 48 + 2 + (2 + 3) + (2 + 2) + 8)
        XCTAssertEqual(RemoteVideoFrame(data), frame)
    }

    func testDeltaFrameWithoutParameterSetsRoundTrips() {
        let frame = sample(seq: 9, keyframe: false, sets: [])
        let data = frame.encoded()
        XCTAssertEqual(data[12], 0)
        XCTAssertEqual(data.count, 48 + 8)
        XCTAssertEqual(RemoteVideoFrame(data), frame)
    }

    func testHeaderIsBigEndian() {
        let data = sample().encoded()
        XCTAssertEqual(Array(data[4..<12]), [0, 0, 0, 7, 0, 0, 0, 1])
        XCTAssertEqual(data[13], 1)
        XCTAssertEqual(Array(data[24..<32]), [0, 0, 0x07, 0x80, 0, 0, 0x04, 0x38])
    }

    func testMalformedMessagesAreRejected() {
        let data = sample().encoded()
        XCTAssertNil(RemoteVideoFrame(Data(data.prefix(47))))
        var wrongMagic = data
        wrongMagic[3] = UInt8(ascii: "2")
        XCTAssertNil(RemoteVideoFrame(wrongMagic))
        var badCodec = data
        badCodec[13] = 9
        XCTAssertNil(RemoteVideoFrame(badCodec))
        // Parameter set length runs past the end.
        XCTAssertNil(RemoteVideoFrame(Data(data.prefix(48 + 2 + 2 + 1))))
    }

    func testAnnexBSplitsOnThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC, 0xDD])
        XCTAssertEqual(RemoteVideoFrame.nalUnits(annexB: stream), [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 0xCC, 0xDD])])
        XCTAssertEqual(RemoteVideoFrame.nalUnits(annexB: Data([1, 2, 3])), [])
    }

    func testLengthPrefixedMatchesAVCC() {
        let out = RemoteVideoFrame.lengthPrefixed([Data([0x65, 1]), Data([0x41])])
        XCTAssertEqual(out, Data([0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41]))
        XCTAssertTrue(RemoteVideoDecoder.isAVCC(out))
        XCTAssertFalse(RemoteVideoDecoder.isAVCC(out.dropLast()))
        XCTAssertFalse(RemoteVideoDecoder.isAVCC(Data()))
        XCTAssertFalse(RemoteVideoDecoder.isAVCC(Data([0, 0, 0, 0])))
    }

    // MARK: - Decode

    /// Encodes one real frame with VideoToolbox, sends it through the wire
    /// format, and decodes it onto a display layer.
    func testRealH264KeyframeDecodes() throws {
        let encoded = try encodeOne(width: 320, height: 180)
        let wire = RemoteVideoFrame(streamID: 1, seq: 1, keyframe: true, codec: .h264, pts: 0, width: 320, height: 180,
                                    frame: CGRect(x: 0, y: 0, width: 640, height: 360),
                                    parameterSets: encoded.sets, accessUnit: encoded.accessUnit)
        let received = try XCTUnwrap(RemoteVideoFrame(wire.encoded()))
        let decoder = RemoteVideoDecoder(layer: AVSampleBufferDisplayLayer())
        XCTAssertEqual(decoder.decode(received), .shown(CGSize(width: 320, height: 180)))
    }

    func testDeltaBeforeKeyframeAsksForOne() throws {
        let encoded = try encodeOne(width: 320, height: 180)
        let decoder = RemoteVideoDecoder(layer: AVSampleBufferDisplayLayer())
        let delta = RemoteVideoFrame(streamID: 1, seq: 1, keyframe: false, codec: .h264, pts: 0, width: 320, height: 180,
                                     frame: .zero, parameterSets: [], accessUnit: encoded.accessUnit)
        XCTAssertEqual(decoder.decode(delta), .needsKeyframe)
    }

    func testStreamHoldsFramesUntilStartAnswersAndAcksEach() throws {
        let encoded = try encodeOne(width: 320, height: 180)
        let stream = RemoteVideoStream()
        let log = Log()
        stream.configure(.init(ack: { id, seq in log.add("ack \(id) \(seq)") },
                               keyframe: { id in log.add("key \(id)") },
                               shown: { picture in log.add("shown \(Int(picture.size.width))") }))
        func frame(_ id: UInt32, _ seq: UInt32, key: Bool) -> Data {
            RemoteVideoFrame(streamID: id, seq: seq, keyframe: key, codec: .h264, pts: 0, width: 320, height: 180,
                             frame: CGRect(x: 0, y: 0, width: 320, height: 180),
                             parameterSets: key ? encoded.sets : [], accessUnit: encoded.accessUnit).encoded()
        }
        stream.begin()
        stream.receive(frame(4, 1, key: false))
        stream.receive(frame(5, 1, key: true))
        XCTAssertEqual(log.lines, [])
        stream.attach(5)
        stream.receive(frame(4, 2, key: false))
        stream.receive(frame(5, 2, key: false))
        XCTAssertEqual(log.lines, ["ack 5 1", "shown 320", "ack 5 2", "shown 320"])
        stream.detach()
        stream.receive(frame(5, 3, key: false))
        XCTAssertEqual(log.lines.count, 4)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        var lines: [String] { lock.withLock { items } }
        func add(_ line: String) { lock.withLock { items.append(line) } }
    }

    private func encodeOne(width: Int, height: Int) throws -> (sets: [Data], accessUnit: Data) {
        var session: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                  codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                  outputCallback: nil, refcon: nil, compressionSessionOut: &session), noErr)
        let compressor = try XCTUnwrap(session)
        defer { VTCompressionSessionInvalidate(compressor) }
        VTSessionSetProperty(compressor, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(compressor, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0x80, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        final class Box: @unchecked Sendable { var sample: CMSampleBuffer? }
        let box = Box()
        let properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        VTCompressionSessionEncodeFrame(compressor, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            if status == noErr { box.sample = sample }
        }
        VTCompressionSessionCompleteFrames(compressor, untilPresentationTimeStamp: .invalid)
        let sample = try XCTUnwrap(box.sample)
        let format = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))

        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                               parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let pointer { sets.append(Data(bytes: pointer, count: size)) }
        }
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &base)
        let accessUnit = Data(bytes: try XCTUnwrap(base), count: length)
        return (sets, accessUnit)
    }
}
