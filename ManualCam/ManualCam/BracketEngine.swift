import AVFoundation
import CoreImage
import Vision

/// 手持多帧对齐：用 Vision 平移配准把目标帧对到参考帧上（包围曝光 HDR、手持慢门、夜景降噪共用）。
/// 只做平移不做旋转/透视，手持轻微晃动够用；配准在缩小图上做，速度快、对噪点不敏感
final class FrameAligner {
    private let reference: CIImage
    private let scale: CGFloat
    private let referenceSmall: CIImage

    /// 配准用的缩略图长边
    private static let registrationSide: CGFloat = 512

    init(reference: CIImage) {
        self.reference = reference
        scale = min(1, Self.registrationSide / max(reference.extent.width, reference.extent.height))
        referenceSmall = Self.downscale(reference, by: scale)
    }

    /// 返回对齐后的目标帧（尺寸与原帧一致；移出画面的边缘用最近像素填充，避免平均后边缘发暗）。
    /// - Parameter exposureCompensation: 目标帧相对参考帧的曝光差（EV），配准前先拉平亮度，包围曝光必需
    func align(_ target: CIImage, exposureCompensation: Float = 0) -> CIImage {
        var small = Self.downscale(target, by: scale)
        if exposureCompensation != 0 {
            small = small.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -exposureCompensation])
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small, options: [:])
        let handler = VNImageRequestHandler(ciImage: referenceSmall, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return target
        }
        let t = observation.alignmentTransform
        // 缩略图上的平移量换算回原图
        let shift = CGAffineTransform(translationX: t.tx / scale, y: t.ty / scale)
        // 位移太大多半是配准失败（画面大幅变化），宁可不对齐
        guard abs(shift.tx) < target.extent.width * 0.15, abs(shift.ty) < target.extent.height * 0.15 else {
            return target
        }
        return target.clampedToExtent().transformed(by: shift).cropped(to: target.extent)
    }

    private static func downscale(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// 包围曝光
enum BracketEngine {

    /// 包围档距（EV）
    static let spreads: [Float] = [0.7, 1, 2, 3]

    /// 生成 -spread / 0 / +spread 三张的手动包围参数。
    /// 以相机当前（测光后）的快门/ISO 为基准，优先改快门；快门到硬件上限时由 ISO 补足剩余的档数
    static func bracketedSettings(device: AVCaptureDevice, spread: Float, count: Int)
        -> [AVCaptureManualExposureBracketedStillImageSettings] {
        let format = device.activeFormat
        let minS = CMTimeGetSeconds(format.minExposureDuration)
        let maxS = CMTimeGetSeconds(format.maxExposureDuration)
        let baseS = CMTimeGetSeconds(device.exposureDuration)
        let baseISO = device.iso

        let half = (count - 1) / 2
        return (0..<count).map { i in
            let ev = Float(i - half) * spread
            let wantS = baseS * pow(2, Double(ev))
            let s = min(max(wantS, minS), maxS)
            // 快门没走完的档数交给 ISO
            let remaining = Float(log2(wantS / s))
            let iso = min(max(baseISO * pow(2, remaining), format.minISO), format.maxISO)
            return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(
                exposureDuration: CMTime(seconds: s, preferredTimescale: 1_000_000_000), iso: iso)
        }
    }

    /// 简易曝光融合（Mertens 思路的单尺度版）：每张按"曝光适中程度"加权平均。
    /// 权重 = 4L(1-L)（L 为感知亮度，0.5 最高，死黑/过曝趋近 0），再大半径模糊权重图避免逐像素跳变产生噪点和断层。
    /// 不做多分辨率金字塔，所以大光比边缘可能有轻微光晕，但不会出现传统 HDR 的"灰片"感。
    ///
    /// 归一化（÷ 权重和）借用预乘 alpha 完成，不需要自定义内核：把权重放进 alpha，
    /// 各帧变成预乘的 (w·I, w)，相加得到 (Σw·I, Σw)，反预乘就是 Σw·I / Σw。
    /// - Parameters:
    ///   - frames: 已对齐的各帧（同尺寸）
    static func fuse(_ frames: [CIImage]) -> CIImage? {
        guard let first = frames.first else { return nil }
        let extent = first.extent
        let sigma = max(extent.width, extent.height) * 0.01
        let clear = CIImage(color: .clear).cropped(to: extent)

        var sum: CIImage?
        for frame in frames {
            let weightAlpha = wellExposedness(of: frame)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: sigma)
                .cropped(to: extent)
                .applyingFilter("CIMaskToAlpha")
            // 输出 = 预乘的 (w·I, w)
            let weighted = frame.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: weightAlpha
            ])
            sum = sum.map { weighted.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? weighted
        }
        // 反预乘得到加权平均色，再把 alpha 直接置 1（settingAlphaOne 不会再按 alpha 缩放颜色）
        return sum?
            .unpremultiplyingAlpha()
            .settingAlphaOne(in: extent)
            .cropped(to: extent)
    }

    /// 灰度权重图（RGB 三通道相同，alpha = 1）
    private static func wellExposedness(of image: CIImage) -> CIImage {
        // 先转回感知（sRGB 伽马）亮度，在线性空间里算的话"适中"会偏向高光
        let luma = image
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        // w = 0.01 + 4L - 4L²（加 0.01 防止全黑/全白处除以 0）
        let coefficients = CIVector(x: 0.01, y: 4, z: -4, w: 0)
        return luma
            .applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": coefficients,
                "inputGreenCoefficients": coefficients,
                "inputBlueCoefficients": coefficients,
                "inputAlphaCoefficients": CIVector(x: 1, y: 0, z: 0, w: 0)
            ])
    }
}
