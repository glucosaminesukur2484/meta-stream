import Combine
import CoreGraphics
import CoreImage
import Foundation
import HaishinKit
import Vision

/// Blurs faces, text (which covers licence plates, house numbers and badges for free -- a plate is text) and
/// barcodes/QR codes out of video before it reaches the encoder. Conforms to HaishinKit's `VideoEffect` and
/// is registered on `mixer.screen` (see Streamer.swift's syncBlurEffect) -- that's the single hook inside
/// MediaMixer's offscreen render pipeline that every video path routed through the mixer passes through:
/// phone camera, camera-off black frames, and (in H.264 mode) decoded glasses frames. HEVC glasses
/// passthrough never reaches the mixer at all, so it can never be blurred -- see adr/0001-blur-forces-transcode.md
/// for why blur forces a transcode instead of silently doing nothing there.
///
/// Threading: `execute` is `nonisolated` and touches plain (non-actor) state, on purpose -- HaishinKit calls
/// it synchronously, once per rendered frame, from its own ScreenActor/rendering context, never from the
/// main actor. Calling it concurrently from two threads at once is not safe (matches HaishinKit's own
/// contract: one VideoTrackScreenObject drives its registered effects serially). Only `stalled` is
/// actor-isolated, since it's the one thing SwiftUI needs to observe.
///
/// Coordinates: Vision's normalized boxes (0...1) use a bottom-left origin, y increasing upward -- the same
/// convention CIImage's `extent` uses. So converting a Vision box into CIImage pixel space (what `execute`
/// does below) is a pure scale, no flip needed. A flip would only be needed if this handed the rect to
/// something top-left/y-down, like UIKit or a CALayer overlay -- this file never does. See Self.demo().
///
/// Diagnostics: this whole pipeline used to be able to fail completely silently -- enabled=true, no crash,
/// no dropped frames, just an unmodified picture -- because nothing logged what detection actually found.
/// `execute` now logs a rate-limited (~1/s, never per-frame) summary of options/counts/composited boxes so
/// that failure mode shows up in the log instead of needing a device test to notice.
@MainActor final class Privacy: ObservableObject, VideoEffect {
    struct Options { var faces = true; var text = true; var barcodes = true }

    /// True once detection hasn't successfully completed a pass in >1s -- the caller should fail closed
    /// (e.g. switch to the same black-frame path setCameraOff already uses) rather than trust this frame.
    @Published private(set) var stalled = false
    nonisolated(unsafe) var options = Options()
    nonisolated(unsafe) var enabled = false   // off by default: blur is an opt-in cost (see the ADR)

    nonisolated private static let detectEveryNFrames = 5
    nonisolated private static let detectAtLeastEvery: TimeInterval = 0.4   // frame-count alone is meaningless when the render rate is low              // ~6 detections/s at 30fps, well inside the 33ms/frame budget shared with decode+encode
    nonisolated private static let detectionMaxDimension: CGFloat = 360 // boxes are normalized, so a small detection frame costs nothing downstream
    nonisolated private static let padFraction: CGFloat = 0.3           // generous margin: motion between detections is the risk, not one frame of under-blur
    nonisolated private static let pixellateScale: CGFloat = 24         // ponytail: fixed block size tuned for 720x1280; scale with frame size/box size if that ever looks wrong
    nonisolated private static let detectStallThreshold: TimeInterval = 3.0   // must exceed the detection interval below, or it alarms on itself
    nonisolated private static let boxCarryCeiling: TimeInterval = 5.0  // belt-and-suspenders: drop ancient boxes even if the caller never looks at `stalled`
    nonisolated private static let diagnosticLogInterval: TimeInterval = 1.0

    // nonisolated(unsafe): VNSequenceRequestHandler is Apple docs' own recommendation for reuse across
    // frames/threads. Swift 6 mode still requires this annotation since its Sendable conformance isn't
    // audited in the SDK.
    nonisolated(unsafe) private let sequenceHandler = VNSequenceRequestHandler()

    nonisolated(unsafe) private var frameCount = 0
    nonisolated(unsafe) private var boxes: [CGRect] = []     // normalized, already padded
    nonisolated(unsafe) private var lastDetectionOK = Date() // "just started" reads as healthy, not stalled
    nonisolated(unsafe) private var stalledShadow = false
    nonisolated(unsafe) private var lastDetectionCounts = (faces: 0, text: 0, barcodes: 0)  // last Vision pass's raw observation counts, for logDiagnostic
    nonisolated(unsafe) private var lastDiagnosticLogAt = Date.distantPast

    /// Hands back an obscured image, or the original image if there's nothing to hide. Called by HaishinKit
    /// once per rendered frame while this is registered on mixer.screen and the mixer is in .offscreen mode
    /// (see Streamer.syncBlurEffect) -- it never runs while disabled or while the mixer is passthrough.
    nonisolated func execute(_ image: CIImage) -> CIImage {
        guard enabled else { return image }
        frameCount += 1
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        // Detect on frame count OR elapsed time: a low offscreen render rate makes "every 5th frame"
        // arbitrarily slow, which is what made the stall alarm fire while detection was succeeding.
        let due = frameCount == 1 || frameCount % Self.detectEveryNFrames == 0
            || Date().timeIntervalSince(lastDetectionOK) >= Self.detectAtLeastEvery
        if due { runDetection(on: image) }
        if Date().timeIntervalSince(lastDetectionOK) > Self.detectStallThreshold { setStalled(true) }
        if Date().timeIntervalSince(lastDetectionOK) > Self.boxCarryCeiling { boxes = [] }

        var result = image
        var compositedCount = 0
        if !boxes.isEmpty {   // nothing to hide: skip the CI render entirely
            let w = extent.width, h = extent.height
            let pixellated = image.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: Self.pixellateScale])
            for box in boxes {
                let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h).intersection(extent)
                guard !rect.isEmpty else { continue }
                result = pixellated.cropped(to: rect).composited(over: result)
                compositedCount += 1
            }
        }
        logDiagnosticIfDue(compositedCount: compositedCount)
        return result
    }

    // MARK: detection

    nonisolated private func runDetection(on image: CIImage) {
        let faceReq = options.faces ? VNDetectFaceRectanglesRequest() : nil
        let textReq = options.text ? VNDetectTextRectanglesRequest() : nil       // region only, no OCR -- also catches plates/badges/receipts/screens for free
        let barcodeReq = options.barcodes ? VNDetectBarcodesRequest() : nil
        let requests: [VNRequest] = [faceReq, textReq, barcodeReq].compactMap { $0 }
        guard !requests.isEmpty else { lastDetectionCounts = (0, 0, 0); markDetected([]); return }

        // Downscale before handing Vision the frame -- boxes are normalized, so detection resolution is
        // free downstream. No pixel-buffer render needed: Vision takes a CIImage directly.
        let extent = image.extent
        let scale = min(1, Self.detectionMaxDimension / max(extent.width, extent.height))
        let small = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image

        do {
            // orientation .up: this receives the same image HaishinKit renders straight from the mixer's
            // video track with no rotation applied, so it's already display-right-side-up.
            try sequenceHandler.perform(requests, on: small, orientation: .up)
            // Reading .results off each concrete request (not casting the merged [VNRequest] array) both
            // sidesteps relying on VNDetectedObjectObservation's cast succeeding for every observation type
            // and gives an exact per-detector count for free -- see logDiagnosticIfDue.
            let faces = (faceReq?.results ?? []).map { Self.pad($0.boundingBox, by: Self.padFraction) }
            let texts = (textReq?.results ?? []).map { Self.pad($0.boundingBox, by: Self.padFraction) }
            let barcodes = (barcodeReq?.results ?? []).map { Self.pad($0.boundingBox, by: Self.padFraction) }
            lastDetectionCounts = (faces.count, texts.count, barcodes.count)
            markDetected(faces + texts + barcodes)
        } catch {
            applog("stream", "privacy detection failed: \(error)", error: true)
            // boxes stay as they are -- carried forward per the fail-safe design; execute()'s staleness
            // check escalates to `stalled` if this keeps happening for a full second.
        }
    }

    nonisolated private func markDetected(_ newBoxes: [CGRect]) {
        lastDetectionOK = Date()
        boxes = newBoxes
        setStalled(false)
    }

    nonisolated private func setStalled(_ value: Bool) {
        guard stalledShadow != value else { return }
        stalledShadow = value
        Task { @MainActor [weak self] in self?.stalled = value }
    }

    /// Rate-limited (~1/s, never per-frame) visibility into an otherwise-silent pipeline: blur enabled with
    /// nothing detected, or detected but nothing composited, previously looked identical to working correctly
    /// -- no error, no dropped frame, no stall. This is what a device test needed to catch that.
    nonisolated private func logDiagnosticIfDue(compositedCount: Int) {
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticLogAt) > Self.diagnosticLogInterval else { return }
        lastDiagnosticLogAt = now
        let opts = "faces=\(options.faces ? "on" : "off") text=\(options.text ? "on" : "off") barcodes=\(options.barcodes ? "on" : "off")"
        applog("stream", "privacy diag: enabled=\(enabled) options(\(opts)) found(faces=\(lastDetectionCounts.faces) text=\(lastDetectionCounts.text) barcodes=\(lastDetectionCounts.barcodes)) boxes=\(boxes.count) composited=\(compositedCount) stalled=\(stalledShadow)")
    }

    // MARK: pure helpers -- see Self.demo()

    nonisolated static func pad(_ box: CGRect, by fraction: CGFloat) -> CGRect {
        let dx = box.width * fraction, dy = box.height * fraction
        return box.insetBy(dx: -dx, dy: -dy).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    nonisolated static func isExpired(lastDetection: Date, now: Date, maxAge: TimeInterval) -> Bool {
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
        // pixel space (what execute() actually does) is a pure scale, no flip:
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
