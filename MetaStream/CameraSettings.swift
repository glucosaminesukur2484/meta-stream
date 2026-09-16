import Foundation
import AVFoundation
import CoreMedia

/// Manual phone-camera controls layered on AVFoundation's automatic defaults. Every mode defaults to
/// "let the system decide" -- manual ISO/shutter/white-balance/lens-position only take effect when their
/// owning toggle is on. Not threaded through goLive()'s `quality:` parameter like PhoneQuality, because
/// ContentView (not touched by this change) builds that call site and doesn't know these fields exist --
/// see loadFromDefaults() below. Re-read and re-applied on every camera attach (switchTo(glasses:) in
/// Streamer.swift), so a front/back switch always gets the current values, not a Go-Live-time snapshot.
struct CameraSettings: Sendable {
    var lens = "wide"                    // "wide" | "ultrawide" | "telephoto"
    var zoom: Double = 1.0

    var focusMode = "continuous"         // "continuous" | "auto" | "manual"
    var lensPosition: Double = 0.5       // 0...1, used only when focusMode == "manual"
    var smoothAutoFocus = true           // designed for video; hunting is very visible while walking
    var faceDrivenAutoFocus = true

    var exposureManual = false
    var exposureBiasEV: Double = 0       // applied under auto exposure; custom mode ignores it (metering only)
    var manualISO: Double = 200
    var manualShutterMs: Double = 33.3   // ~1/30s
    var lowLightBoost = true

    var whiteBalanceManual = false
    var whiteBalanceTemperature: Double = 5500   // Kelvin
    var whiteBalanceTint: Double = 0

    var hdr = "auto"                     // "auto" | "on" | "off"
    var torchLevel: Double = 0           // 0 = off, else 0<level<=1
    var mirrored = false
    var geometricDistortionCorrection = true
}

extension CameraSettings {
    /// AppStorage backs UserDefaults.standard under the same keys SettingsView's Camera screen uses; read
    /// them directly here instead of widening goLive()'s parameter list (see the type doc above). Absent
    /// keys -- Settings never opened -- keep the struct's own defaults rather than reading UserDefaults'
    /// zero-value (0.0/false), which would silently mean "0x zoom" / "torch off forever" instead of
    /// "user hasn't chosen yet".
    static func loadFromDefaults() -> CameraSettings {
        let d = UserDefaults.standard
        var s = CameraSettings()
        if let v = d.object(forKey: "camLens") as? String { s.lens = v }
        if let v = d.object(forKey: "camZoom") as? Double { s.zoom = v }
        if let v = d.object(forKey: "camFocusMode") as? String { s.focusMode = v }
        if let v = d.object(forKey: "camLensPosition") as? Double { s.lensPosition = v }
        if let v = d.object(forKey: "camSmoothAutoFocus") as? Bool { s.smoothAutoFocus = v }
        if let v = d.object(forKey: "camFaceDrivenAutoFocus") as? Bool { s.faceDrivenAutoFocus = v }
        if let v = d.object(forKey: "camExposureManual") as? Bool { s.exposureManual = v }
        if let v = d.object(forKey: "camExposureBiasEV") as? Double { s.exposureBiasEV = v }
        if let v = d.object(forKey: "camManualISO") as? Double { s.manualISO = v }
        if let v = d.object(forKey: "camManualShutterMs") as? Double { s.manualShutterMs = v }
        if let v = d.object(forKey: "camLowLightBoost") as? Bool { s.lowLightBoost = v }
        if let v = d.object(forKey: "camWhiteBalanceManual") as? Bool { s.whiteBalanceManual = v }
        if let v = d.object(forKey: "camWBTemperature") as? Double { s.whiteBalanceTemperature = v }
        if let v = d.object(forKey: "camWBTint") as? Double { s.whiteBalanceTint = v }
        if let v = d.object(forKey: "camHDR") as? String { s.hdr = v }
        if let v = d.object(forKey: "camTorchLevel") as? Double { s.torchLevel = v }
        if let v = d.object(forKey: "camMirrored") as? Bool { s.mirrored = v }
        if let v = d.object(forKey: "camGDC") as? Bool { s.geometricDistortionCorrection = v }
        return s
    }
}

/// Lens choice is not a device property -- it's a different physical AVCaptureDevice. Discovering one
/// per attach (rather than caching) is what makes "re-evaluated per camera" (front vs back capability)
/// actually happen: DiscoverySession runs fresh against whichever position is being attached right now.
enum CameraLens: String, CaseIterable {
    case wide, ultrawide, telephoto

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide: return .builtInWideAngleCamera
        case .ultrawide: return .builtInUltraWideCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }
    var label: String {
        switch self {
        case .wide: return "Wide (1x)"
        case .ultrawide: return "Ultra-wide"
        case .telephoto: return "Telephoto"
        }
    }
}

extension CameraSettings {
    /// Discovers the physical camera for `lens` at `position`, falling back to the standard wide lens
    /// (present on every iPhone that has a camera at all) when the device has no ultra-wide/telephoto --
    /// e.g. non-Pro models have no telephoto, older/smaller ones may lack ultra-wide too. Shared by
    /// Streamer's attach path and the Settings screen's capability probe, so both agree on which device
    /// a given lens choice actually resolves to.
    static func device(lens: String, position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let type = CameraLens(rawValue: lens)?.deviceType ?? .builtInWideAngleCamera
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: position).devices.first
        if let found { return found }
        if type == .builtInWideAngleCamera { return nil }   // no camera at all on this position
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Which of the three lenses physically exist at `position` -- CameraLens.allCases filtered by
    /// DiscoverySession actually finding a match, NOT device(lens:position:)'s fallback-to-wide (that
    /// fallback is right for a caller already committed to one lens; here we want the honest list so the
    /// live lens-switch strip never offers a lens that would silently become wide when tapped).
    static func availableLenses(position: AVCaptureDevice.Position) -> [CameraLens] {
        CameraLens.allCases.filter {
            AVCaptureDevice.DiscoverySession(deviceTypes: [$0.deviceType], mediaType: .video, position: position).devices.first != nil
        }
    }

    // MARK: pure clamps -- see Self.demo(). One generic clamp for zoom/ISO/bias/lens-position/torch (all
    // "keep a requested Double in range"); ms->s is the one conversion, kept separate. apply(_:to:) below
    // calls these exact functions, so the self-check exercises production logic, not a parallel copy.
    static func clamped(_ requested: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(Swift.max(requested, lo), hi)
    }
    static func clampedSeconds(_ requestedMs: Double, minSeconds lo: Double, maxSeconds hi: Double) -> Double {
        clamped(requestedMs / 1000, min: lo, max: hi)
    }
    static func clampedGains(_ g: AVCaptureDevice.WhiteBalanceGains, max hi: Float) -> AVCaptureDevice.WhiteBalanceGains {
        func c(_ v: Float) -> Float { Swift.min(Swift.max(v, 1.0), hi) }
        return .init(redGain: c(g.redGain), greenGain: c(g.greenGain), blueGain: c(g.blueGain))
    }

    /// Maps a tap point normalized to the PREVIEW VIEW's own bounds (0...1, origin top-left -- what you get
    /// dividing a SwiftUI tap location by the view's size) into AVCaptureDevice.focusPointOfInterest /
    /// exposurePointOfInterest space. Apple defines that space as FIXED to the sensor's natural landscape
    /// orientation regardless of the video orientation the capture connection is rotating to -- NOT the
    /// same space as the point you tapped on screen. AVCaptureVideoPreviewLayer.captureDevicePointConverted(
    /// fromLayerPoint:) does this conversion for free, but this app's live preview is an
    /// AVSampleBufferDisplayLayer (shared with the glasses' raw HEVC feed, see ContentView's PreviewView),
    /// not an AVCaptureVideoPreviewLayer, so that convenience API isn't reachable here -- these are the same
    /// four 90-degree-rotation cases it computes internally, hand-rolled.
    /// mirrored flips the x axis afterward, for the front camera when Settings' "Mirror" output toggle is on.
    /// ponytail: does NOT correct for .resizeAspect letterbox/pillarbox between the view's aspect ratio and
    /// the captured video's -- assumes the tap point lines up with the video pixel at that fraction of the
    /// view, which is only exact when they share an aspect ratio (close but not exact for 720x1280 on a
    /// ~19.5:9 screen). Upgrade path: pass the actual output size in and clip/rescale against the letterboxed
    /// rect before rotating. Also NOT verified against real camera hardware (no device available here) --
    /// this is the standard published mapping, but the mirrored front-camera case especially is worth
    /// confirming against one real tap before trusting it blind.
    static func devicePoint(forViewPoint p: CGPoint, orientation: AVCaptureVideoOrientation, mirrored: Bool) -> CGPoint {
        var x: CGFloat, y: CGFloat
        switch orientation {
        case .portrait:           x = p.y;     y = 1 - p.x
        case .portraitUpsideDown: x = 1 - p.y; y = p.x
        case .landscapeRight:     x = p.x;     y = p.y
        case .landscapeLeft:      x = 1 - p.x; y = 1 - p.y
        @unknown default:         x = p.x;     y = p.y
        }
        if mirrored { x = 1 - x }
        return CGPoint(x: Swift.min(Swift.max(x, 0), 1), y: Swift.min(Swift.max(y, 0), 1))
    }

    /// Applies every control this app exposes to `device`, gating each on the runtime support check
    /// Apple's docs specify (isXSupported/isXAvailable) so hardware that lacks a control is skipped and
    /// logged rather than silently doing nothing (isSmoothAutoFocusEnabled etc.) or throwing
    /// (setExposureModeCustom, setTorchModeOn). Owns its own lockForConfiguration()/unlockForConfiguration()
    /// pair -- every setter below requires the device to already be locked or it raises NSGenericException
    /// (documented on AVCaptureDevice, confirmed directly on setTorchModeOn(level:)) -- so it's safe to call
    /// from inside Streamer's attachVideo configuration closure without that closure locking separately.
    /// `log: false` skips the applog call at the bottom only -- every device write below still runs every
    /// call. Streamer.applyCameraSettings() passes false because it's called on every live-slider tick and
    /// LogStore.add() rejoins up to 2000 lines on every call (see Log.swift); paying that during a fast drag
    /// would be felt as lag even though the actual camera writes are cheap.
    static func apply(_ s: CameraSettings, to device: AVCaptureDevice, log: Bool = true) {
        do { try device.lockForConfiguration() } catch {
            applog("stream", "camera settings: lockForConfiguration failed: \(error.localizedDescription)", error: true)
            return
        }
        defer { device.unlockForConfiguration() }
        var applied: [String] = []
        var skipped: [String] = []

        let zoom = clamped(s.zoom, min: device.minAvailableVideoZoomFactor, max: device.maxAvailableVideoZoomFactor)
        device.videoZoomFactor = zoom
        applied.append("zoom=\(String(format: "%.2f", zoom))x")

        switch s.focusMode {
        case "manual":
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: Float(clamped(s.lensPosition, min: 0, max: 1)))
                applied.append("focus=manual(\(s.lensPosition))")
            } else { skipped.append("manual focus") }
        case "auto":
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus; applied.append("focus=auto") }
            else { skipped.append("auto focus") }
        default:
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus; applied.append("focus=continuous") }
            else { skipped.append("continuous focus") }
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = s.smoothAutoFocus
            applied.append("smoothAF=\(s.smoothAutoFocus)")
        } else { skipped.append("smooth autofocus") }
        // No documented isFaceDrivenAutoFocusSupported flag (checked Apple's docs directly) -- gate on
        // continuous AF support instead, the mode this actually affects.
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = false
            device.isFaceDrivenAutoFocusEnabled = s.faceDrivenAutoFocus
            applied.append("faceAF=\(s.faceDrivenAutoFocus)")
        }

        if s.exposureManual, device.isExposureModeSupported(.custom) {
            let iso = Float(clamped(s.manualISO, min: Double(device.activeFormat.minISO), max: Double(device.activeFormat.maxISO)))
            let seconds = clampedSeconds(s.manualShutterMs, minSeconds: device.activeFormat.minExposureDuration.seconds, maxSeconds: device.activeFormat.maxExposureDuration.seconds)
            device.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000), iso: iso)
            applied.append("exposure=manual(iso=\(Int(iso)),\(String(format: "%.4f", seconds))s)")
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            let bias = Float(clamped(s.exposureBiasEV, min: Double(device.minExposureTargetBias), max: Double(device.maxExposureTargetBias)))
            device.setExposureTargetBias(bias)
            applied.append("exposure=auto(ev=\(bias))")
        } else { skipped.append("exposure") }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = s.lowLightBoost
            applied.append("lowLightBoost=\(s.lowLightBoost)")
        } else { skipped.append("low-light boost") }

        if s.whiteBalanceManual, device.isWhiteBalanceModeSupported(.locked) {
            let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(s.whiteBalanceTemperature), tint: Float(s.whiteBalanceTint))
            let gains = clampedGains(device.deviceWhiteBalanceGains(for: tt), max: device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: gains)
            applied.append("wb=manual(\(Int(s.whiteBalanceTemperature))K)")
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            applied.append("wb=auto")
        } else { skipped.append("white balance") }

        if s.hdr != "auto" {
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = s.hdr == "on"
                applied.append("hdr=\(s.hdr)")
            } else { skipped.append("HDR") }
        }

        if device.hasTorch {
            if s.torchLevel > 0, device.isTorchModeSupported(.on) {
                do { try device.setTorchModeOn(level: Float(clamped(s.torchLevel, min: 0.01, max: 1))) }
                catch { skipped.append("torch (\(error.localizedDescription))") }
                applied.append("torch=\(String(format: "%.0f%%", s.torchLevel * 100))")
            } else if device.isTorchModeSupported(.off) {
                device.torchMode = .off
            }
        } else { skipped.append("torch") }

        if device.isGeometricDistortionCorrectionSupported {
            device.isGeometricDistortionCorrectionEnabled = s.geometricDistortionCorrection
            applied.append("gdc=\(s.geometricDistortionCorrection)")
        } else { skipped.append("geometric distortion correction") }

        if log {
            applog("stream", "camera settings: \(applied.joined(separator: " "))"
                + (skipped.isEmpty ? "" : " -- unsupported on this camera, skipped: \(skipped.joined(separator: ", "))"))
        }
    }
}

/// What SettingsView's Camera screen greys controls out against -- probed fresh whenever the lens or
/// fallback-camera position picker changes, since front/back (and wide/ultrawide/telephoto) genuinely
/// differ. `nil` fields mean "camera unavailable" (e.g. no camera at all in the Simulator), in which case
/// the whole screen shows its no-camera notice instead of guessing.
struct CameraCapabilities {
    var zoomRange: ClosedRange<Double>
    var focusAuto: Bool
    var focusContinuous: Bool
    var focusManual: Bool
    var smoothAutoFocus: Bool
    var exposureManual: Bool
    var isoRange: ClosedRange<Double>
    var shutterRangeMs: ClosedRange<Double>
    var exposureBiasRange: ClosedRange<Double>
    var lowLightBoost: Bool
    var whiteBalanceManual: Bool
    var hdr: Bool
    var torch: Bool
    var geometricDistortionCorrection: Bool

    static func probe(lens: String, position: AVCaptureDevice.Position) -> CameraCapabilities? {
        guard let device = CameraSettings.device(lens: lens, position: position) else { return nil }
        let f = device.activeFormat
        return CameraCapabilities(
            zoomRange: device.minAvailableVideoZoomFactor...max(device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor),
            focusAuto: device.isFocusModeSupported(.autoFocus),
            focusContinuous: device.isFocusModeSupported(.continuousAutoFocus),
            focusManual: device.isLockingFocusWithCustomLensPositionSupported,
            smoothAutoFocus: device.isSmoothAutoFocusSupported,
            exposureManual: device.isExposureModeSupported(.custom),
            isoRange: Double(f.minISO)...Double(max(f.minISO, f.maxISO)),
            shutterRangeMs: (f.minExposureDuration.seconds * 1000)...max(f.minExposureDuration.seconds * 1000, f.maxExposureDuration.seconds * 1000),
            exposureBiasRange: Double(device.minExposureTargetBias)...Double(max(device.minExposureTargetBias, device.maxExposureTargetBias)),
            lowLightBoost: device.isLowLightBoostSupported,
            whiteBalanceManual: device.isWhiteBalanceModeSupported(.locked),
            hdr: f.isVideoHDRSupported,
            torch: device.hasTorch,
            geometricDistortionCorrection: device.isGeometricDistortionCorrectionSupported)
    }
}

/// One entry in the live control strip ContentView opens over the preview (see ContentView's
/// cameraControlStrip). Tap-to-focus/expose is deliberately not a case here -- it's a gesture directly on
/// the preview, not a strip button (see Streamer.tapToFocus). Membership and order are user-configurable
/// (Settings gets the picker UI separately); ContentView renders `LiveCameraControl.order(from:)`'s result
/// rather than a hardcoded HStack, so adding/removing/reordering entries there needs no ContentView change.
enum LiveCameraControl: String, CaseIterable {
    case lens, zoom, exposure, torch, whiteBalanceLock

    static let storageKey = "liveCameraControlOrder"
    static let defaultOrder: [LiveCameraControl] = [.lens, .zoom, .exposure, .torch, .whiteBalanceLock]
    static let defaultOrderRaw = defaultOrder.map(\.rawValue).joined(separator: ",")

    /// Pure parse: comma-joined rawValues (UserDefaults.standard[storageKey]) -> ordered cases. Unknown
    /// tokens (a future rename, a stale value from an older build) are dropped rather than crashing the
    /// strip; an empty string or one that parses to nothing falls back to defaultOrder so there's never a
    /// stored value that leaves the strip with no way to bring controls back. See Self.demo() below.
    static func order(from raw: String) -> [LiveCameraControl] {
        let parsed = raw.split(separator: ",").compactMap { LiveCameraControl(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? defaultOrder : parsed
    }
}

#if DEBUG
extension CameraSettings {
    /// Self-check for the pure conversions -- no device, no capture session.
    static func demo() {
        assert(clamped(5, min: 1, max: 3) == 3, "zoom ceilings")
        assert(clamped(0.2, min: 1, max: 3) == 1, "zoom floors")
        assert(clamped(2, min: 1, max: 3) == 2, "zoom passes through in range")
        assert(clamped(50, min: 100, max: 800) == 100, "ISO floors")
        assert(clamped(2000, min: 100, max: 800) == 800, "ISO ceilings")
        assert(clamped(-10, min: -2, max: 2) == -2, "EV floors")
        assert(clamped(10, min: -2, max: 2) == 2, "EV ceilings")
        assert(abs(clampedSeconds(33.3, minSeconds: 0.001, maxSeconds: 1) - 0.0333) < 0.0001, "ms -> s")
        assert(clampedSeconds(9999, minSeconds: 0.001, maxSeconds: 0.5) == 0.5, "shutter ceilings")
        let gains = AVCaptureDevice.WhiteBalanceGains(redGain: 10, greenGain: 0.1, blueGain: 3)
        let gainsClamped = clampedGains(gains, max: 4)
        assert(gainsClamped.redGain == 4 && gainsClamped.greenGain == 1 && gainsClamped.blueGain == 3, "WB gains clamp to [1, maxGain]")

        // devicePoint: a tap at the view's top-left, each orientation, unmirrored.
        let tl = CGPoint(x: 0, y: 0)
        assert(devicePoint(forViewPoint: tl, orientation: .portrait, mirrored: false) == CGPoint(x: 0, y: 1), "portrait top-left")
        assert(devicePoint(forViewPoint: tl, orientation: .portraitUpsideDown, mirrored: false) == CGPoint(x: 1, y: 0), "portraitUpsideDown top-left")
        assert(devicePoint(forViewPoint: tl, orientation: .landscapeRight, mirrored: false) == CGPoint(x: 0, y: 0), "landscapeRight top-left")
        assert(devicePoint(forViewPoint: tl, orientation: .landscapeLeft, mirrored: false) == CGPoint(x: 1, y: 1), "landscapeLeft top-left")
        assert(devicePoint(forViewPoint: tl, orientation: .portrait, mirrored: true) == CGPoint(x: 1, y: 1), "mirrored flips x")
        let center = CGPoint(x: 0.5, y: 0.5)
        assert(devicePoint(forViewPoint: center, orientation: .portrait, mirrored: false) == CGPoint(x: 0.5, y: 0.5), "center maps to center in every orientation")

        // LiveCameraControl.order(from:): valid, unknown-token-dropping, and fallback cases.
        assert(LiveCameraControl.order(from: "zoom,torch") == [.zoom, .torch], "valid order parses in place")
        assert(LiveCameraControl.order(from: "zoom,bogus,torch") == [.zoom, .torch], "unknown tokens dropped")
        assert(LiveCameraControl.order(from: "") == LiveCameraControl.defaultOrder, "empty falls back to default")
        assert(LiveCameraControl.order(from: "nope,also-nope") == LiveCameraControl.defaultOrder, "all-unknown falls back to default")

        print("CameraSettings.demo() ok")
    }
}
#endif
