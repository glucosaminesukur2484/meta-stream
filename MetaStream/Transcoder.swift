import CoreMedia
import VideoToolbox

/// Decodes the glasses' compressed HEVC frames into pixel buffers so HaishinKit can re-encode them as H.264.
/// Needed for Kick (rejects H.265) and Twitch without Affiliate. Runs on the SDK's frame thread, decodes synchronously
/// to keep frame order. ponytail: hardware decode may be refused while backgrounded; then frames simply stop.
final class Transcoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let sink: @Sendable (CMSampleBuffer) -> Void
    private var failures = 0

    init(sink: @escaping @Sendable (CMSampleBuffer) -> Void) { self.sink = sink }

    func decode(_ sb: CMSampleBuffer) {
        guard let fd = sb.formatDescription else { return }
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fd) }) ?? true {
            invalidate()
            var s: VTDecompressionSession?
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                                      imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                      decompressionSessionOut: &s)
            guard status == noErr, let s else { applog("stream", "HEVC decoder create failed: \(status)", error: true); return }
            session = s
            format = fd
            applog("stream", "HEVC decoder ready (transcoding to H.264)")
        }
        guard let session else { return }
        let pts = sb.presentationTimeStamp
        let dur = sb.duration
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [sink] status, _, image, ipts, _ in
            guard status == noErr, let image else { return }
            var fdOut: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &fdOut)
            guard let fdOut else { return }
            var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: ipts.isValid ? ipts : pts, decodeTimeStamp: .invalid)
            var out: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: fdOut,
                                                     sampleTiming: &timing, sampleBufferOut: &out)
            if let out { sink(out) }
        }
        if status != noErr {
            failures += 1
            if failures == 1 || failures % 100 == 0 { applog("stream", "HEVC decode failed: \(status) (x\(failures))", error: true) }
            // -12903 kVTInvalidSessionErr: iOS killed the hardware decoder because the app went to the background.
            // Drop the session so the next frame recreates it; that fails while backgrounded and succeeds on return.
            if status == kVTInvalidSessionErr { invalidate() }
        } else if failures > 0 {
            applog("stream", "HEVC decoder recovered after \(failures) failed frames"); failures = 0
        }
    }

    func invalidate() {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        format = nil
    }
}
