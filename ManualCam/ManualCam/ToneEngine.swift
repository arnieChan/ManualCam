import CoreImage

/// 色调条目（内置预设或用户导入的 LUT）
struct ToneItem: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 色调引擎：所有预设统一走 3D LUT 管线。
/// 内置预设 = CoreImage 滤镜链，首次使用时烘焙成 LUT 缓存；
/// 用户预设 = 直接解析 .cube 文件。预览/成片共用同一 LUT，保证所见即所得。
enum ToneEngine {

    static let standardID = "standard"

    static let builtIns: [ToneItem] = [
        ToneItem(id: standardID, name: "标准"),
        ToneItem(id: "filmNegative", name: "胶片负片"),
        ToneItem(id: "coolClear", name: "冷调清透"),
        ToneItem(id: "warmGerman", name: "暖调德味")
    ]

    /// 烘焙缓存（线程安全用锁保护，视频帧回调在后台线程访问）
    private static var bakedLUTs: [String: CubeLUT] = [:]
    private static let lock = NSLock()

    static func apply(id: String, to image: CIImage) -> CIImage {
        if id == standardID { return image }

        // 用户导入的 LUT
        if id.hasPrefix("custom-") {
            if let lut = CustomLUTStore.shared.lut(for: id) {
                return lut.apply(to: image)
            }
            return image
        }

        // 内置预设：取缓存的烘焙 LUT，没有就现场烘焙
        lock.lock()
        if let lut = bakedLUTs[id] {
            lock.unlock()
            return lut.apply(to: image)
        }
        lock.unlock()

        guard let chain = filterChain(for: id) else { return image }
        let lut = LUTBaker.bake(chain: chain)

        lock.lock()
        bakedLUTs[id] = lut
        lock.unlock()
        return lut.apply(to: image)
    }

    // MARK: - 内置预设的滤镜链定义

    private static func filterChain(for id: String) -> ((CIImage) -> CIImage)? {
        switch id {
        case "filmNegative":
            // 思路：压低对比、抬升阴影（胶片曲线）、轻微降饱和、色温微暖
            return { input in
                var img = input.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.85,
                    kCIInputContrastKey: 0.92,
                    kCIInputBrightnessKey: 0.02
                ])
                img = img.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0.0, y: 0.04),
                    "inputPoint1": CIVector(x: 0.25, y: 0.24),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: 0.76),
                    "inputPoint4": CIVector(x: 1.0, y: 0.96)
                ])
                img = img.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6000, y: 4)
                ])
                return img
            }

        case "coolClear":
            // 思路：冷色温、提亮度、清透高饱和
            return { input in
                var img = input.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 7800, y: -2)
                ])
                img = img.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.08,
                    kCIInputContrastKey: 1.02,
                    kCIInputBrightnessKey: 0.04
                ])
                return img
            }

        case "warmGerman":
            // 思路：暖色温、高对比、高饱和、暗角——所谓"德味"
            return { input in
                var img = input.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 5400, y: 6)
                ])
                img = img.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 1.18,
                    kCIInputContrastKey: 1.15,
                    kCIInputBrightnessKey: -0.02
                ])
                img = img.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: 0.9,
                    kCIInputRadiusKey: 1.6
                ])
                return img
            }

        default:
            return nil
        }
    }
}
