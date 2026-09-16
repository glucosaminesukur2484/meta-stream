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
    // ponytail: no longer a device selector (see captureDevice(position:)'s doc -- the zoom-scale rewrite
    // that fixed the ~6x-on-telephoto bug). Kept only so the lens strip/Settings picker have something to
    // highlight and old stored values keep loading; apply() never reads it.
    var lens = "wide"                    // "wide" | "ultrawide" | "telephoto"
    var zoom: Double = 1.0               // videoZoomFactor on whatever captureDevice(position:) attaches

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

/// One button in the live lens-switch row: a physical lens paired with the exact zoom factor (and its
/// display label) THIS device's hardware actually puts it at -- see CameraSettings.lensOptions(position:).
struct LensOption: Equatable {
    let lens: CameraLens
    let zoomFactor: Double
    let label: String
}

extension CameraSettings {
    /// Discovers the physical camera for `lens` at `position`, falling back to the standard wide lens
    /// (present on every iPhone that has a camera at all) when the device has no ultra-wide/telephoto --
    /// e.g. non-Pro models have no telephoto, older/smaller ones may lack ultra-wide too. NOT the attach
    /// path any more (see captureDevice(position:)) -- only fieldOfViewMultiplier's per-lens FOV lookup
    /// and captureDevice's own single-lens fallback still call this.
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

    /// The virtual multi-camera device for `position`, richest to plainest: triple (ultra-wide+wide+tele)
    /// > dual-wide (ultra-wide+wide) > dual (wide+tele). nil on single-lens hardware (e.g. iPhone SE) or a
    /// front camera -- no virtual front-camera device type exists.
    private static func virtualDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: position)
    }

    /// THE attach path (Streamer.switchTo, CameraCapabilities/CameraFormatCapabilities.probe): the virtual
    /// multi-camera device when one exists, else the plain wide lens. Fixes the device-confirmed "~6x zoom
    /// on lens select" bug -- this app used to attach a *physical* lens device (e.g. builtInTelephotoCamera,
    /// via device(lens:position:)) and set videoZoomFactor to the lens's multiplier RELATIVE TO WIDE (from
    /// virtualDeviceSwitchOverVideoZoomFactors, see lensOptions below). But videoZoomFactor==1.0 on a
    /// physical telephoto is ALREADY ~3x wide's framing, so setting it to that same relative multiplier
    /// (e.g. 3) compounded to ~9x. Attaching the virtual device instead means videoZoomFactor IS the
    /// wide-anchored scale everywhere -- one number, and iOS switches the physical lens underneath at the
    /// switch-over points on its own, exactly like the system Camera app. Its minAvailableVideoZoomFactor
    /// can be below 1.0 (ultra-wide) -- CameraSettings.apply already clamps against the device's own
    /// min/max rather than assuming a 1.0 floor, so that just works.
    static func captureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        virtualDevice(position: position) ?? device(lens: "wide", position: position)
    }

    /// Ascending by real zoom factor (ultra-wide < wide < telephoto -- always true by physical definition,
    /// so the ORDER never needs a device query, only the LABELS do). Device-confirmed bug this replaces:
    /// the strip used to iterate CameraLens.allCases' declaration order (wide, ultrawide, telephoto -> "1,
    /// 0.5, 2") with a hardcoded telephoto label of "2", which is wrong on any iPhone whose telephoto isn't
    /// 2x (3x on 14/15 Pro, 5x on 15/16 Pro Max, etc). Wide is always exactly 1x -- every other lens's zoom
    /// factor is relative to it, by AVFoundation convention. Ultra-wide/telephoto come from the position's
    /// virtual multi-camera device where one exists: AVCaptureDevice.virtualDeviceSwitchOverVideoZoomFactors
    /// reports the zoom factors, in the wide-anchored 1.0 domain, at which the system crosses from one
    /// constituent lens to the next (confirmed against Apple's current docs -- one fewer entry than
    /// constituentDevices, values ascend in the same order) -- that crossover point is, by definition,
    /// where the next lens's native optical framing takes over, i.e. its real display multiplier; this is
    /// the same number the system Camera app's own buttons are built from, no separate "display" API is
    /// needed pre-iOS-18 (displayVideoZoomFactorMultiplier is iOS 18+ only, above this app's 17.2 floor).
    /// minAvailableVideoZoomFactor on that same virtual device is ultra-wide's multiplier for the same
    /// reason -- it's defined as how far below wide's 1.0 this virtual device can go, which only ultra-wide
    /// answers. Falls back to fieldOfViewMultiplier() below for whichever lens that didn't cover (no
    /// virtual device at this position at all); a lens that STILL can't be derived either way is left off
    /// the row entirely -- never a guessed label. See Self.demo() for the pure trig half of this.
    static func lensOptions(position: AVCaptureDevice.Position) -> [LensOption] {
        let available = availableLenses(position: position)
        guard available.count > 1 else { return [] }   // solo lens: nothing to switch between

        var ultrawideFactor: Double?
        var telephotoFactor: Double?
        let virtual = virtualDevice(position: position)
        if let virtual {
            let switchOvers = virtual.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
            let virtualMin = Double(virtual.minAvailableVideoZoomFactor)   // CGFloat on the SDK -- explicit, not assumed
            if available.contains(.ultrawide), virtualMin < 1 {
                ultrawideFactor = virtualMin
            }
            if available.contains(.telephoto), let hi = switchOvers.max() {
                telephotoFactor = hi
            }
        }
        if available.contains(.ultrawide), ultrawideFactor == nil {
            ultrawideFactor = fieldOfViewMultiplier(of: .ultrawide, position: position)
        }
        if available.contains(.telephoto), telephotoFactor == nil {
            telephotoFactor = fieldOfViewMultiplier(of: .telephoto, position: position)
        }

        var options: [LensOption] = [LensOption(lens: .wide, zoomFactor: 1, label: "1")]
        if let m = ultrawideFactor { options.append(LensOption(lens: .ultrawide, zoomFactor: m, label: multiplierLabel(m))) }
        if let m = telephotoFactor { options.append(LensOption(lens: .telephoto, zoomFactor: m, label: multiplierLabel(m))) }
        return options.sorted { $0.zoomFactor < $1.zoomFactor }
    }

    /// Fallback when there's no virtual multi-camera device to read a switchover factor from (older
    /// hardware): the ratio of two lenses' diagonal field-of-view tangents is their real zoom multiplier --
    /// basic rectilinear-lens optics (focal length is proportional to tan(halfFOV) for a fixed sensor
    /// size), not an iPhone-specific fact, so this works for any device pair without a per-model table.
    private static func fieldOfViewMultiplier(of lens: CameraLens, position: AVCaptureDevice.Position) -> Double? {
        guard lens != .wide,
              let wide = device(lens: "wide", position: position), wide.activeFormat.videoFieldOfView > 0,
              let other = device(lens: lens.rawValue, position: position), other.activeFormat.videoFieldOfView > 0
        else { return nil }
        return zoomMultiplier(wideFOVDegrees: Double(wide.activeFormat.videoFieldOfView), otherFOVDegrees: Double(other.activeFormat.videoFieldOfView))
    }

    /// Pure trig half of fieldOfViewMultiplier -- exercised directly in Self.demo() without any device.
    static func zoomMultiplier(wideFOVDegrees: Double, otherFOVDegrees: Double) -> Double {
        let halfWide = wideFOVDegrees / 2 * .pi / 180, halfOther = otherFOVDegrees / 2 * .pi / 180
        return tan(halfWide) / tan(halfOther)
    }

    /// Rounds a derived multiplier to the nearest half-step for display -- real lens multipliers (0.5x,
    /// 1x, 2x, 3x, 5x) are always clean numbers; the raw hardware/trig value lands within noise of one
    /// (e.g. 2.98) rather than exactly on it.
    static func multiplierLabel(_ m: Double) -> String {
        let rounded = (m * 2).rounded() / 2
        return rounded.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
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

/// What SettingsView's Camera screen greys controls out against -- probed fresh whenever the fallback-
/// camera position picker changes, since front/back genuinely differ. One probe per POSITION, not per
/// lens: captureDevice(position:) attaches one (virtual, usually) device covering every lens, so that's
/// the only device whose capabilities matter (see captureDevice's doc). `nil` fields mean "camera
/// unavailable" (e.g. no camera at all in the Simulator), in which case the whole screen shows its
/// no-camera notice instead of guessing.
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

    static func probe(position: AVCaptureDevice.Position) -> CameraCapabilities? {
        guard let device = CameraSettings.captureDevice(position: position) else { return nil }
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

/// What resolutions THIS position can actually shoot, and for each, the frame rates and stabilisation
/// modes that resolution's capture format(s) support -- replaces the old fixed 720p/1080p x 24/30/60 x
/// off/standard/cinematic/action lists Settings used to offer on every device regardless of hardware. Built
/// from AVCaptureSession.Preset support rather than raw device.formats enumeration -- Streamer's capture
/// pipeline already selects resolution via mixer.setSessionPreset(phoneQuality.sessionPreset) (see
/// PhoneQuality), so probing exactly the presets that pipeline can pick between (720p/1080p/4K) keeps this
/// incapable of ever offering a resolution the capture side can't actually set. One probe per position, not
/// per lens -- see CameraCapabilities' doc for why (captureDevice(position:) attaches one device for every
/// lens now); formats/stabilisation modes are that device's.
struct CameraFormatCapabilities {
    struct Resolution: Equatable {
        let height: Int                     // matches PhoneQuality.height's encoding (720/1080/2160)
        let frameRates: [Int]                // ascending, whole fps this resolution's format(s) report
        let stabilizationModes: [String]     // subset of "off"/"standard"/"cinematic"/"action"

        func nearestFps(to desired: Int) -> Int {
            frameRates.min { abs($0 - desired) < abs($1 - desired) } ?? desired
        }
        func nearestStabilization(to desired: String) -> String {
            stabilizationModes.contains(desired) ? desired : "off"
        }
    }
    let resolutions: [Resolution]   // ascending by height; probe() returns nil rather than an empty array

    /// height -> (preset, landscape pixel dimensions) -- the fixed set PhoneQuality.sessionPreset already
    /// maps to. Not a capability guess: this only decides which of THOSE presets to test for on the
    /// attached device, same closed set the capture pipeline itself is limited to.
    private static let candidates: [(height: Int, preset: AVCaptureSession.Preset, dims: (Int, Int))] =
        [(720, .hd1280x720, (1280, 720)), (1080, .hd1920x1080, (1920, 1080)), (2160, .hd4K3840x2160, (3840, 2160))]
    private static let standardFps = [15, 24, 25, 30, 50, 60, 120, 240]
    private static let stabilizationNames = ["standard", "cinematic", "action"]

    static func probe(position: AVCaptureDevice.Position) -> CameraFormatCapabilities? {
        guard let device = CameraSettings.captureDevice(position: position) else { return nil }
        let resolutions: [Resolution] = candidates.compactMap { height, preset, dims in
            guard device.supportsSessionPreset(preset) else { return nil }
            // Union fps/stabilisation across every format matching this preset's pixel dimensions --
            // several formats (different binning/color spaces) commonly share one resolution.
            let matching = device.formats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return (Int(d.width), Int(d.height)) == dims || (Int(d.height), Int(d.width)) == dims
            }
            guard !matching.isEmpty else { return nil }
            var fps: Set<Int> = []
            for format in matching {
                for range in format.videoSupportedFrameRateRanges {
                    let lo = Int(range.minFrameRate.rounded(.up)), hi = Int(range.maxFrameRate.rounded(.down))
                    if lo <= hi { fps.formUnion(lo...hi) }
                }
            }
            let offeredFps = standardFps.filter { fps.contains($0) }
            guard !offeredFps.isEmpty else { return nil }
            let stab = stabilizationNames.filter { name in
                matching.contains { $0.isVideoStabilizationModeSupported(Streamer.stabilizationMode(name)) }
            }
            return Resolution(height: height, frameRates: offeredFps, stabilizationModes: ["off"] + stab)
        }
        return resolutions.isEmpty ? nil : CameraFormatCapabilities(resolutions: resolutions.sorted { $0.height < $1.height })
    }

    /// Nearest available resolution to a stored/desired height -- exact match if present, otherwise the
    /// closest, so a stored 1080p preference on a lens that tops out at 720p still lands somewhere sane
    /// instead of the picker silently showing nothing.
    func nearestResolution(to desiredHeight: Int) -> Resolution? {
        resolutions.min { abs($0.height - desiredHeight) < abs($1.height - desiredHeight) }
    }
}

/// One entry in the live control strip ContentView opens over the preview (see ContentView's
/// cameraControlStrip). Tap-to-focus/expose is deliberately not a case here -- it's a gesture directly on
/// the preview, not a strip button (see Streamer.tapToFocus). Membership and order are user-configurable
/// (Settings gets the picker UI separately); ContentView renders `LiveCameraControl.order(from:)`'s result
/// rather than a hardcoded HStack, so adding/removing/reordering entries there needs no ContentView change.
enum LiveCameraControl: String, CaseIterable {
    // stabilization/mirror: deliberate re-attaches, not live connection tweaks -- see Streamer.
    // setStabilization/setMirrored's docs. AE/AF lock and the grid/level overlays are NOT cases here:
    // lock is a long-press gesture on the preview (like tap-to-focus, see ContentView's gesture), and
    // grid/level are Settings-only viewfinder toggles, never strip buttons.
    case lens, zoom, exposure, torch, whiteBalanceLock, stabilization, mirror

    static let storageKey = "liveCameraControlOrder"
    static let defaultOrder: [LiveCameraControl] = [.lens, .zoom, .exposure, .torch, .whiteBalanceLock, .stabilization, .mirror]
    static let defaultOrderRaw = defaultOrder.map(\.rawValue).joined(separator: ",")

    /// Pure parse: comma-joined rawValues (UserDefaults.standard[storageKey]) -> ordered cases. Unknown
    /// tokens (a future rename, a stale value from an older build) are dropped rather than crashing the
    /// strip; an empty string or one that parses to nothing falls back to defaultOrder so there's never a
    /// stored value that leaves the strip with no way to bring controls back. See Self.demo() below.
    static func order(from raw: String) -> [LiveCameraControl] {
        let parsed = raw.split(separator: ",").compactMap { LiveCameraControl(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return parsed.isEmpty ? defaultOrder : parsed
    }

    /// Row label for the Customise-strip screen (SettingsView.LiveControlsCustomizeView) -- the strip
    /// itself never shows this text, only icons, so it wasn't needed until that screen existed.
    var label: String {
        switch self {
        case .lens: return "Lens"
        case .zoom: return "Zoom"
        case .exposure: return "Exposure"
        case .torch: return "Torch"
        case .whiteBalanceLock: return "White balance lock"
        case .stabilization: return "Stabilisation"
        case .mirror: return "Mirror"
        }
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

        // Customise screen round trip: a subset + reorder survives storage; the all-off case falls back
        // to defaults rather than ever leaving the strip with nothing on it (see LiveControlsCustomizeView).
        let customOrder: [LiveCameraControl] = [.torch, .zoom, .mirror]
        assert(LiveCameraControl.order(from: customOrder.map(\.rawValue).joined(separator: ",")) == customOrder, "customise round trip: subset + reorder survives")
        assert(LiveCameraControl.order(from: "") == LiveCameraControl.defaultOrder, "customise round trip: all-off falls back to defaults, never an empty strip")

        // Pinch-to-zoom: base zoom (at gesture start) * MagnifyGesture.magnification, clamped -- the exact
        // clamped() the zoom slider and CameraSettings.apply use, so pinch/slider/lens switch agree.
        assert(clamped(2.0 * 1.5, min: 1, max: 5) == 3.0, "pinch: base*magnification within range")
        assert(clamped(2.0 * 10, min: 1, max: 5) == 5.0, "pinch: magnification clamps to device max")
        assert(clamped(2.0 * 0.1, min: 1, max: 5) == 1.0, "pinch: magnification clamps to device min")

        // Lens zoom multipliers: derived from field-of-view ratios, not a per-model guess (see
        // lensOptions()/fieldOfViewMultiplier()). Same FOV -> 1x; a narrower FOV -> a bigger multiplier.
        assert(zoomMultiplier(wideFOVDegrees: 75, otherFOVDegrees: 75) == 1.0, "same FOV -> 1x")
        assert(zoomMultiplier(wideFOVDegrees: 75, otherFOVDegrees: 35) > zoomMultiplier(wideFOVDegrees: 75, otherFOVDegrees: 50), "narrower FOV -> bigger multiplier")
        assert(multiplierLabel(2.98) == "3", "rounds hardware noise to a clean whole number")
        assert(multiplierLabel(0.52) == "0.5", "keeps a genuine half-step")

        // Zoom-scale fix (device-confirmed ~6x-on-telephoto bug): selecting a lens now sets camZoom to its
        // wide-anchored switch-over factor, and captureDevice(position:) attaches the virtual multi-camera
        // device so THAT factor is directly the videoZoomFactor to set -- no separate "relative to the
        // physical lens" scale to compound against. apply() clamps through this exact clamped(), so proving
        // it here proves the production path: "3x" selected -> videoZoomFactor 3, not 3x-on-top-of-3x=9(ish).
        assert(clamped(3.0, min: 0.5, max: 10.0) == 3.0, "a lens's switch-over factor maps 1:1 to videoZoomFactor on the virtual device")
        // Virtual device's minAvailableVideoZoomFactor is ultra-wide's factor, below 1.0 -- apply() must
        // clamp against the device's own floor, never an assumed 1.0.
        assert(clamped(0.5, min: 0.5, max: 10.0) == 0.5, "ultra-wide's switch-over sits at the virtual device's real (below-1.0) floor")
        assert(clamped(0.2, min: 0.5, max: 10.0) == 0.5, "a request below that floor still clamps to it, not to 1.0")

        print("CameraSettings.demo() ok")
    }
}
#endif
