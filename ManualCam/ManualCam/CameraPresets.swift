import Foundation
import Combine

/// 自定义拍摄档（类似机身上的 C1/C2/C3）：一键保存 / 调用整套参数
struct CameraPreset: Codable, Equatable {
    var captureMode: CaptureMode
    var photoFormat: PhotoFormat
    var toneID: String

    var autoFocus: Bool
    var lensPosition: Float
    var autoISO: Bool
    var iso: Float
    var autoShutter: Bool
    var shutterSeconds: Float
    var exposureBias: Float
    var autoWhiteBalance: Bool
    var temperature: Float
    /// 后加的字段用可选，旧版本存的档解码时不会失败
    var tint: Float?

    var longExposureSeconds: Double
    var longExposureBlend: LongExposureBlend
    var apertureF: Float

    /// 菜单里显示的一行摘要，如「慢门 · S 1/30 · ISO A · 4s 流水」
    var summary: String {
        var parts = [captureMode.name]
        let program: ExposureProgram = switch (autoISO, autoShutter) {
        case (true, true): .program
        case (true, false): .shutterPriority
        case (false, true): .isoPriority
        case (false, false): .manual
        }
        parts.append(program.badge + (autoShutter ? "" : " " + ExposureStops.shutterLabel(shutterSeconds)))
        parts.append(autoISO ? "ISO A" : "ISO \(Int(iso))")
        if !autoWhiteBalance { parts.append("\(Int(temperature))K") }
        switch captureMode {
        case .longExposure: parts.append("\(Int(longExposureSeconds))s \(longExposureBlend.name)")
        case .bokeh: parts.append(ExposureStops.apertureLabel(apertureF))
        case .photo: if photoFormat != .heif { parts.append(photoFormat.name) }
        case .bracket: break
        }
        return parts.joined(separator: " · ")
    }
}

/// C1~C3 存在 UserDefaults 里（数据量很小，不需要数据库）
final class PresetStore: ObservableObject {
    static let slotNames = ["C1", "C2", "C3"]
    private static let key = "cameraPresets.v1"

    @Published private(set) var presets: [String: CameraPreset] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: CameraPreset].self, from: data) {
            presets = saved
        }
    }

    func save(_ preset: CameraPreset, to slot: String) {
        presets[slot] = preset
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension CameraManager {

    func makePreset() -> CameraPreset {
        CameraPreset(captureMode: captureMode, photoFormat: photoFormat, toneID: toneID,
                     autoFocus: autoFocus, lensPosition: lensPosition,
                     autoISO: autoISO, iso: iso,
                     autoShutter: autoShutter, shutterSeconds: shutterSeconds,
                     exposureBias: exposureBias,
                     autoWhiteBalance: autoWhiteBalance, temperature: temperature, tint: tint,
                     longExposureSeconds: longExposureSeconds, longExposureBlend: longExposureBlend,
                     apertureF: apertureF)
    }

    /// 先切模式（可能会换镜头组），再写参数；数值超出当前镜头范围时由各 apply 函数夹回硬件范围
    func apply(_ preset: CameraPreset) {
        guard longExposureProgress == nil, countdown == nil else { return }
        captureMode = preset.captureMode
        if supportedFormats.contains(preset.photoFormat) { photoFormat = preset.photoFormat }
        toneID = preset.toneID

        lensPosition = preset.lensPosition
        autoFocus = preset.autoFocus
        // 先写数值再切自动开关，避免切到手动的一瞬间用旧值曝光
        iso = preset.iso
        shutterSeconds = preset.shutterSeconds
        autoISO = preset.autoISO
        autoShutter = preset.autoShutter
        exposureBias = preset.exposureBias
        temperature = preset.temperature
        tint = preset.tint ?? 0
        autoWhiteBalance = preset.autoWhiteBalance

        longExposureSeconds = preset.longExposureSeconds
        longExposureBlend = preset.longExposureBlend
        apertureF = preset.apertureF
    }
}
