import Combine
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Blurs faces, text (which covers licence plates, house numbers and badges for free -- a plate is text) and
/// barcodes/QR codes out of decoded video before it reaches the mixer. Sits right after Transcoder's HEVC
/// decode, on the same CVPixelBuffer -- see adr/0001-blur-forces-transcode.md for why this exists at all.
///
/// Threading: `process` is `nonisolated` and touches plain (non-actor) state, on purpose -- it's meant to be
/// called synchronously, once per decoded frame, from the same serial thread every time (the VTDecompressionSession
/// callback thread Transcoder.decode() already runs on; see Transcoder's own header comment). Calling it
/// concurrently from two threads at once is not safe. Only `stalled` is actor-isolated, since it's the one
/// thing SwiftUI needs to observe.
///
/// Coordinates: Vision's normalized boxes (0...1) use a bottom-left origin, y increasing upward -- the same
/// convention CIImage's `extent` uses. So converting a Vision box into CIImage pixel space (what `process`
/// does below) is a pure scale, no flip needed. A flip would only be needed if this handed the rect to
/// something top-left/y-down, like UIKit or a CALayer overlay -- this file never does. See Self.demo().
@MainActor final class Privacy: ObservableObject {
    struct Options { var faces = true; var text = true; var barcodes = true }

    /// True once detection hasn't successfully completed a pass in >1s -- the caller should fail closed
    /// (e.g. switch to the same black-frame path setCameraOff already uses) rather than trust this frame.
    @Published private(set) var stalled = false
    nonisolated(unsafe) var options = Options()
    nonisolated(unsafe) var enabled = false   // off by default: blur is an opt-in cost (see the ADR)

    private static let detectEveryNFrames = 5              // ~6 detections/s at 30fps, well inside the 33ms/frame budget shared with decode+encode
    private static let detectionMaxDimension: CGFloat = 360 // boxes are normalized, so a small detection frame costs nothing downstream
    private static let padFraction: CGFloat = 0.3           // generous margin: motion between detections is the risk, not one frame of under-blur
    private static let pixellateScale: CGFloat = 24         // ponytail: fixed block size tuned for 720x1280; scale with frame size/box size if that ever looks wrong
    private static let detectStallThreshold: TimeInterval = 1.0
    private static let boxCarryCeiling: TimeInterval = 5.0  // belt-and-suspenders: drop ancient boxes even if the caller never looks at `stalled`

    private let sequenceHandler = VNSequenceRequestHandler()
    private let ciContext = CIContext()

    nonisolated(unsafe) private var frameCount = 0
    nonisolated(unsafe) private var boxes: [CGRect] = []     // normalized, already padded
    nonisolated(unsafe) private var lastDetectionOK = Date() // "just started" reads as healthy, not stalled
    nonisolated(unsafe) private var stalledShadow = false
    nonisolated(unsafe) private var detectPool: CVPixelBufferPool?
    nonisolated(unsafe) private var detectPoolSize = (0, 0)
    nonisolated(unsafe) private var outputPool: CVPixelBufferPool?
    nonisolated(unsafe) private var outputPoolSize = (0, 0)

    /// Hands back an obscured frame, or nil if a safe frame couldn't be produced -- caller must not publish
    /// that frame. Call serially, once per decoded frame, always from the same thread (see the header note).
    nonisolated func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard enabled else { return pixelBuffer }
        frameCount += 1
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return pixelBuffer }
        let full = CIImage(cvPixelBuffer: pixelBuffer)

        if frameCount == 1 || frameCount % Self.detectEveryNFrames == 0 { runDetection(on: full, width: width, height: height) }
        if Date().timeIntervalSince(lastDetectionOK) > Self.detectStallThreshold { setStalled(true) }
        if Date().timeIntervalSince(lastDetectionOK) > Self.boxCarryCeiling { boxes = [] }

        guard !boxes.isEmpty else { return pixelBuffer }   // nothing to hide: skip the CI render entirely

        let w = CGFloat(width), h = CGFloat(height)
        let pixellated = full.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: Self.pixellateScale])
        var composited = full
        for box in boxes {
            let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h).intersection(full.extent)
            guard !rect.isEmpty else { continue }
            composited = pixellated.cropped(to: rect).composited(over: composited)
        }

        guard let out = pooledBuffer(pool: &outputPool, size: &outputPoolSize, width: width, height: height) else {
            applog("stream", "privacy: output pixel buffer alloc failed, dropping frame", error: true)
            return nil
        }
        ciContext.render(composited, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
        return out
    }

    // MARK: detection

    private func runDetection(on full: CIImage, width: Int, height: Int) {
        var requests: [VNRequest] = []
        if options.faces { requests.append(VNDetectFaceRectanglesRequest()) }
        if options.text { requests.append(VNDetectTextRectanglesRequest()) }   // region only, no OCR -- also catches plates/badges/receipts/screens for free
        if options.barcodes { requests.append(VNDetectBarcodesRequest()) }
        guard !requests.isEmpty else { markDetected([]); return }

        let scale = min(1, Self.detectionMaxDimension / CGFloat(max(width, height)))
        let smallW = max(1, Int(CGFloat(width) * scale)), smallH = max(1, Int(CGFloat(height) * scale))
        guard let small = pooledBuffer(pool: &detectPool, size: &detectPoolSize, width: smallW, height: smallH) else { return }
        ciContext.render(full.transformed(by: CGAffineTransform(scaleX: scale, y: scale)), to: small,
                         bounds: CGRect(x: 0, y: 0, width: CGFloat(smallW), height: CGFloat(smallH)), colorSpace: nil)

        do {
            // orientation .up: this receives the same buffer AVSampleBufferDisplayLayer enqueues straight to
            // the preview elsewhere in Streamer with no rotation applied, so it's already display-right-side-up.
            try sequenceHandler.perform(requests, on: small, orientation: .up)
            let found = requests.flatMap { ($0.results as? [VNDetectedObjectObservation])?.map { Self.pad($0.boundingBox, by: Self.padFraction) } ?? [] }
            markDetected(found)
        } catch {
            applog("stream", "privacy detection failed: \(error)", error: true)
            // boxes stay as they are -- carried forward per the fail-safe design; process()'s staleness
            // check escalates to `stalled` if this keeps happening for a full second.
        }
    }

    private func markDetected(_ newBoxes: [CGRect]) {
        lastDetectionOK = Date()
        boxes = newBoxes
        setStalled(false)
    }

    private func setStalled(_ value: Bool) {
        guard stalledShadow != value else { return }
        stalledShadow = value
        Task { @MainActor [weak self] in self?.stalled = value }
    }

    // MARK: pixel buffer pools (detection-scale scratch buffer + full-size output buffer)

    /// One pool per use (detect vs. output), rebuilt only if the requested size changes -- both are fixed
    /// for the life of a session in practice, since goLive() fixes the encoder geometry once (see Streamer).
    private func pooledBuffer(pool: inout CVPixelBufferPool?, size: inout (Int, Int), width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || size != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            size = (width, height)
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    // MARK: pure helpers -- see Self.demo()

    static func pad(_ box: CGRect, by fraction: CGFloat) -> CGRect {
        let dx = box.width * fraction, dy = box.height * fraction
        return box.insetBy(dx: -dx, dy: -dy).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    static func isExpired(lastDetection: Date, now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(lastDetection) > maxAge
    }
}

#if DEBUG
extension Privacy {
    /// Self-check for the two places a bug here would silently blur the wrong region or the wrong duration:
    /// the normalized-to-pixel conversion (and why it needs no flip here), and the padding/expiry math.
    /// No camera, no framework -- pure functions and CGRect/Date arithmetic only.
    static func demo() {
        // Vision and CIImage both use bottom-left, y-up coordinates, so scaling a Vision box into CIImage
        // pixel space (what process() actually does) is a pure scale, no flip:
        let box = CGRect(x: 0.25, y: 0.0, width: 0.5, height: 0.5)   // sits in Vision's bottom half
        let px = CGRect(x: box.minX * 1000, y: box.minY * 800, width: box.width * 1000, height: box.height * 800)
        assert(px == CGRect(x: 250, y: 0, width: 500, height: 400), "pure scale, matches CIImage's own bottom-left origin")
        // handing that same rect to something top-left/y-down (UIKit, a CALayer overlay -- this file never
        // does) would need an explicit flip:
        assert(800 - px.minY - px.height == 400, "flipped y for a box sitting in Vision's bottom half lands in the top half up there")

        let padded = pad(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), by: 0.3)
        assert(abs(padded.width - 0.32) < 0.001, "30% margin on each side grows width by 60% of the original")
        assert(abs(padded.minX - 0.34) < 0.001, "padding also shifts the origin outward")
        let clamped = pad(CGRect(x: 0, y: 0, width: 0.1, height: 0.1), by: 0.3)
        assert(clamped.minX == 0 && clamped.minY == 0, "padding clamps to the frame, never goes negative")

        let t0 = Date()
        assert(!isExpired(lastDetection: t0, now: t0.addingTimeInterval(0.5), maxAge: 5), "inside the carry window")
        assert(isExpired(lastDetection: t0, now: t0.addingTimeInterval(6), maxAge: 5), "past the carry window")

        print("Privacy.demo() ok")
    }
}
#endif
