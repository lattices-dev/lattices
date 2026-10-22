import AVFoundation
import CoreMedia
import Foundation

/// Hardware decode of `capture.stream` frames onto an
/// `AVSampleBufferDisplayLayer`. Not thread-safe: one caller at a time.
final class RemoteVideoDecoder {
    enum Outcome: Equatable {
        /// Enqueued; the size is the picture the layer will show.
        case shown(CGSize)
        /// Unusable until the next keyframe.
        case needsKeyframe
    }

    private let renderer: AVSampleBufferVideoRenderer
    private var format: CMVideoFormatDescription?
    private var formatCodec: RemoteVideoFrame.Codec?
    private var parameterSets: [Data] = []
    private var size: CGSize = .zero
    private var synced = false

    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
    }

    /// Forget the decode chain. `clear` also blanks the picture on screen.
    func reset(clear: Bool) {
        synced = false
        renderer.flush(removingDisplayedImage: clear, completionHandler: nil)
    }

    func decode(_ frame: RemoteVideoFrame) -> Outcome {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            reset(clear: false)
            return .needsKeyframe
        }
        if !frame.parameterSets.isEmpty, frame.parameterSets != parameterSets || frame.codec != formatCodec {
            format = Self.format(frame.codec, parameterSets: frame.parameterSets)
            formatCodec = frame.codec
            parameterSets = frame.parameterSets
            if let format {
                let dims = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
                size = CGSize(width: dims.width, height: dims.height)
            } else {
                synced = false
            }
        }
        if frame.keyframe, format != nil, frame.codec == formatCodec { synced = true }
        guard synced, let format, Self.isAVCC(frame.accessUnit),
              let sample = Self.sample(frame, format: format) else {
            synced = false
            return .needsKeyframe
        }
        renderer.enqueue(sample)
        if size == .zero { size = CGSize(width: Int(frame.width), height: Int(frame.height)) }
        return .shown(size)
    }

    // MARK: - CoreMedia

    static func format(_ codec: RemoteVideoFrame.Codec, parameterSets sets: [Data]) -> CMVideoFormatDescription? {
        guard !sets.isEmpty, sets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        var format: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    static func sample(_ frame: RemoteVideoFrame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = frame.accessUnit.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = frame.accessUnit.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame.pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sizes = [length]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.keyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// True when `data` is one or more whole u32-length-prefixed NAL units.
    static func isAVCC(_ data: Data) -> Bool {
        var offset = data.startIndex
        guard offset < data.endIndex else { return false }
        while offset < data.endIndex {
            guard data.endIndex - offset >= 4 else { return false }
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard length > 0, data.endIndex - offset >= length else { return false }
            offset += length
        }
        return true
    }
}

/// The video half of one viewer. Frames arrive on the connection's queue and
/// are decoded there; the session hears about pictures on the main actor.
final class RemoteVideoStream: @unchecked Sendable {
    struct Picture: Equatable {
        var frame: CGRect
        var size: CGSize
    }

    struct Hooks {
        var ack: @Sendable (_ streamID: UInt32, _ seq: UInt32) -> Void
        var keyframe: @Sendable (_ streamID: UInt32) -> Void
        var shown: @Sendable (Picture) -> Void
    }

    let layer: AVSampleBufferDisplayLayer

    private let lock = NSLock()
    private let decoder: RemoteVideoDecoder
    private var hooks: Hooks?
    private var streamID: UInt32?
    /// The stream just left, whose frames can trail its stop.
    private var retired: UInt32?
    private var starting = false
    private var held: [RemoteVideoFrame] = []
    private var lastKeyframeAsk = Date.distantPast

    /// Call on the main thread.
    init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        decoder = RemoteVideoDecoder(layer: layer)
    }

    func configure(_ hooks: Hooks?) {
        lock.withLock { self.hooks = hooks }
    }

    /// A `capture.stream.start` is on its way: hold frames until its id is known.
    func begin() {
        lock.withLock {
            if let streamID { retired = streamID }
            streamID = nil
            starting = true
            held.removeAll()
            lastKeyframeAsk = .distantPast
            decoder.reset(clear: false)
        }
    }

    func attach(_ id: UInt32) {
        lock.withLock {
            streamID = id
            starting = false
            let waiting = held
            held.removeAll()
            for frame in waiting where frame.streamID == id { process(frame) }
        }
    }

    func detach(clear: Bool = false) {
        lock.withLock {
            if let streamID { retired = streamID }
            streamID = nil
            starting = false
            held.removeAll()
            decoder.reset(clear: clear)
        }
    }

    /// On the connection's queue.
    func receive(_ data: Data) {
        guard let frame = RemoteVideoFrame(data) else { return }
        lock.withLock {
            if starting, streamID == nil {
                if frame.streamID != retired, held.count < 16 { held.append(frame) }
                return
            }
            guard frame.streamID == streamID else { return }
            process(frame)
        }
    }

    /// Under `lock`. Every frame is acked, shown or not: the host counts them.
    private func process(_ frame: RemoteVideoFrame) {
        hooks?.ack(frame.streamID, frame.seq)
        switch decoder.decode(frame) {
        case .shown(let size):
            hooks?.shown(Picture(frame: frame.frame, size: size))
        case .needsKeyframe:
            let now = Date()
            guard now.timeIntervalSince(lastKeyframeAsk) > 0.5 else { return }
            lastKeyframeAsk = now
            hooks?.keyframe(frame.streamID)
        }
    }
}
