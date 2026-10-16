import CoreImage
import CoreMedia

/// 慢门合成方式
enum LongExposureBlend: String, CaseIterable, Identifiable, Codable {
    /// 逐帧平均：流水拉丝、人群消失、云朵流动（相当于加了 ND 镜的长曝光）
    case average
    /// 逐帧取最亮：车轨、光绘、星轨（亮的轨迹全部保留，暗部不会被抬亮）
    case lighten
    /// 手持夜景：逐帧对齐后平均，N 帧噪点降到约 1/√N，画面不拉丝
    case night

    var id: String { rawValue }

    var name: String {
        switch self {
        case .average: return "流水"
        case .lighten: return "光轨"
        case .night: return "夜景"
        }
    }

    /// 夜景必须对齐（否则手持就是一张糊片）
    var requiresAlignment: Bool { self == .night }
}

/// 多帧堆栈长曝光：iPhone 单帧快门硬件上限约 1s，更长的慢门靠连续预览帧合成。
///
/// 每帧的曝光仍由 ISO/快门决定（决定画面亮度），合成时长决定"运动被拉多长"。
/// 只在 videoQueue 上使用，不做线程保护。
final class LongExposureStacker {
    let duration: Double
    let blend: LongExposureBlend
    /// 手持模式：每帧先对齐到第一帧再叠加。静止的背景保持清晰，运动物体（水流、车灯）照样拉出轨迹
    let aligns: Bool
    private var aligner: FrameAligner?

    /// 合成缓冲区边长上限：RGBAf 每像素 16 字节，3024 长边约 110MB，再大内存吃紧
    private static let maxLongSide: CGFloat = 3024

    private var accumulator: CIImageAccumulator?
    private var startTime: CMTime?
    private var scale: CGFloat = 1
    private(set) var frameCount = 0
    private(set) var progress: Double = 0

    init(duration: Double, blend: LongExposureBlend, aligns: Bool) {
        self.duration = duration
        self.blend = blend
        self.aligns = aligns || blend.requiresAlignment
    }

    var isFinished: Bool { progress >= 1 }

    /// 当前合成结果（未调色，传感器方向）
    var image: CIImage? { accumulator?.image() }

    /// 叠加一帧，返回进度 0~1
    @discardableResult
    func add(_ frame: CIImage, at time: CMTime) -> Double {
        guard let accumulator else {
            if aligns { aligner = FrameAligner(reference: frame) }
            let longSide = max(frame.extent.width, frame.extent.height)
            scale = min(1, Self.maxLongSide / longSide)
            let first = scaled(frame)
            // 用 32 位浮点累加：几百帧的 1/n 增量在 8/16 位里会被舍入吃掉，平均值会偏向前几帧
            guard let acc = CIImageAccumulator(extent: first.extent, format: .RGBAf) else { return 1 }
            acc.setImage(first)
            self.accumulator = acc
            startTime = time
            frameCount = 1
            return 0
        }

        frameCount += 1
        let current = accumulator.image()
        let incoming = scaled(aligner?.align(frame) ?? frame)
        let blended: CIImage
        switch blend {
        case .average, .night:
            // 增量平均：acc = acc + (frame - acc) / n，等价于前 n 帧的算术平均
            blended = current.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: incoming,
                kCIInputTimeKey: 1.0 / Double(frameCount)
            ])
        case .lighten:
            blended = incoming.applyingFilter("CILightenBlendMode", parameters: [
                kCIInputBackgroundImageKey: current
            ])
        }
        accumulator.setImage(blended.cropped(to: accumulator.extent))

        if let startTime {
            progress = min(CMTimeGetSeconds(CMTimeSubtract(time, startTime)) / duration, 1)
        }
        return progress
    }

    private func scaled(_ image: CIImage) -> CIImage {
        guard scale < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ])
    }
}
