import AVFoundation
import AVKit
import SwiftUI

// MARK: - 实体按键快门（音量键 / 相机控制键按压）

/// 挂到界面上的隐形视图，接收系统的拍摄按键事件：音量 +/- 键、iPhone 16 起的「相机控制」按压。
/// 要求 AVCaptureSession 正在运行，系统才会把按键路由给 App（否则音量键照常调音量）
struct HardwareShutterButton: UIViewRepresentable {
    /// 按下（连拍模式用来开始连拍）
    let onPress: () -> Void
    /// 松开（普通模式在这里拍照，和系统相机一致；连拍模式在这里停止）
    let onRelease: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPress: onPress, onRelease: onRelease) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        if #available(iOS 17.2, *) {
            let coordinator = context.coordinator
            let interaction = AVCaptureEventInteraction { event in
                switch event.phase {
                case .began: coordinator.onPress()
                case .ended: coordinator.onRelease()
                default: break   // cancelled：按键被系统收回（如来电），什么也不做
                }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPress = onPress
        context.coordinator.onRelease = onRelease
    }

    final class Coordinator {
        var onPress: () -> Void
        var onRelease: () -> Void
        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }
    }
}

// MARK: - 相机控制键拨盘（iPhone 16 及以后，iOS 18）

/// 相机控制键上可轻滑切换的拨盘。保存引用是为了 App 内改参数时把拨盘位置同步过去
@available(iOS 18.0, *)
final class CaptureControlSet {
    var shutter: AVCaptureIndexPicker?
    var iso: AVCaptureIndexPicker?
    var aperture: AVCaptureIndexPicker?
    var mode: AVCaptureIndexPicker?
    var shutterStops: [Float] = []
    var isoStops: [Float] = []
}

extension CameraManager {

    /// 按当前镜头重建相机控制键拨盘：快门、ISO、曝光补偿、变焦、光圈（虚化）、拍摄模式。
    /// 快门/ISO 第 0 档是「自动」，拨到具体数值即切成手动——对应 S 档 / ISO 优先 / M 档。
    /// 必须在 sessionQueue、beginConfiguration/commitConfiguration 之间调用
    func configureCaptureControls() {
        guard #available(iOS 18.0, *), session.supportsControls, let device else { return }
        session.controls.forEach { session.removeControl($0) }

        let format = device.activeFormat
        let set = CaptureControlSet()
        set.shutterStops = ExposureStops.stops(
            ExposureStops.shutter,
            in: Float(CMTimeGetSeconds(format.minExposureDuration))...Float(CMTimeGetSeconds(format.maxExposureDuration)))
        set.isoStops = ExposureStops.stops(ExposureStops.iso, in: format.minISO...format.maxISO)

        let shutter = AVCaptureIndexPicker("快门", symbolName: "timer",
                                           localizedIndexTitles: ["自动"] + set.shutterStops.map(ExposureStops.shutterLabel))
        shutter.setActionQueue(.main) { [weak self] index in
            guard let self else { return }
            if index == 0 {
                self.autoShutter = true
            } else {
                self.autoShutter = false
                self.shutterSeconds = set.shutterStops[min(index - 1, set.shutterStops.count - 1)]
            }
        }

        let iso = AVCaptureIndexPicker("ISO", symbolName: "sun.max",
                                       localizedIndexTitles: ["自动"] + set.isoStops.map { "\(Int($0))" })
        iso.setActionQueue(.main) { [weak self] index in
            guard let self else { return }
            if index == 0 {
                self.autoISO = true
            } else {
                self.autoISO = false
                self.iso = set.isoStops[min(index - 1, set.isoStops.count - 1)]
            }
        }

        // 系统曝光补偿 / 变焦拨盘直接驱动设备，这里只把结果同步回 UI 状态
        let ev = AVCaptureSystemExposureBiasSlider(device: device) { [weak self] bias in
            DispatchQueue.main.async { self?.exposureBias = bias }
        }
        let zoom = AVCaptureSystemZoomSlider(device: device) { [weak self] factor in
            DispatchQueue.main.async {
                guard let self else { return }
                self.zoomDrivenBySystemControl = true
                self.zoomFactor = factor
                self.zoomDrivenBySystemControl = false
            }
        }

        let aperture = AVCaptureIndexPicker("虚化光圈", symbolName: "camera.aperture",
                                            localizedIndexTitles: ExposureStops.aperture.map(ExposureStops.apertureLabel))
        aperture.setActionQueue(.main) { [weak self] index in
            self?.apertureF = ExposureStops.aperture[index]
        }

        let mode = AVCaptureIndexPicker("模式", symbolName: "camera",
                                        localizedIndexTitles: CaptureMode.allCases.map(\.name))
        mode.setActionQueue(.main) { [weak self] index in
            self?.captureMode = CaptureMode.allCases[index]
        }

        set.shutter = shutter
        set.iso = iso
        set.aperture = aperture
        set.mode = mode

        // 机身可挂的拨盘数有限（session.maxControlsCount），按常用程度依次加
        let controls: [AVCaptureControl] = [shutter, iso, ev, zoom, aperture, mode]
        for control in controls where session.canAddControl(control) {
            session.addControl(control)
        }
        captureControlSet = set
        DispatchQueue.main.async { self.syncCaptureControls() }
    }

    /// App 里改了参数后，把相机控制键拨盘的位置同步过去（必须在主线程，即拨盘的 action queue）
    func syncCaptureControls() {
        guard #available(iOS 18.0, *), let set = captureControlSet as? CaptureControlSet else { return }
        set.shutter?.selectedIndex = autoShutter ? 0 : 1 + ExposureStops.nearestIndex(of: shutterSeconds, in: set.shutterStops)
        set.iso?.selectedIndex = autoISO ? 0 : 1 + ExposureStops.nearestIndex(of: iso, in: set.isoStops)
        set.aperture?.selectedIndex = ExposureStops.nearestIndex(of: apertureF, in: ExposureStops.aperture)
        set.mode?.selectedIndex = CaptureMode.allCases.firstIndex(of: captureMode) ?? 0
        set.aperture?.isEnabled = captureMode == .bokeh
    }
}

@available(iOS 18.0, *)
extension CameraManager: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}

    /// 拨盘展开时系统会在屏幕边缘显示刻度，按 HIG 收起 App 自己的参数面板，避免两套控件叠在一起
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        controlsOverlayActive = true
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        controlsOverlayActive = false
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        controlsOverlayActive = false
    }
}
