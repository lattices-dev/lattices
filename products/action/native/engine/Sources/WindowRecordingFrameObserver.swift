import ActionCore
import CoreMedia
import Darwin
import Foundation
@preconcurrency import ScreenCaptureKit

/// No per-frame logging or disk I/O. The ScreenCaptureKit callback and the final
/// snapshot both access timing through this dedicated serial queue.
final class WindowRecordingFrameObserver: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.action.recording-probe.frames", qos: .userInitiated)
    private var timing: ActionRecordingFrameTiming

    override init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        timing = ActionRecordingFrameTiming(
            startedAt: Date().ISO8601Format(),
            startedHostTimeSeconds: ProcessInfo.processInfo.systemUptime,
            machTimebaseNumerator: timebase.numer,
            machTimebaseDenominator: timebase.denom
        )
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        dispatchPrecondition(condition: .onQueue(queue))
        let attachment = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first
        timing.append(
            presentationTimeSeconds: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)),
            arrivalHostTimeSeconds: ProcessInfo.processInfo.systemUptime,
            status: (attachment?[.status] as? NSNumber)?.intValue,
            displayTimeTicks: (attachment?[.displayTime] as? NSNumber)?.uint64Value,
            valid: CMSampleBufferIsValid(sampleBuffer)
        )
    }

    func write(to path: String) throws {
        let snapshot = queue.sync { timing }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
