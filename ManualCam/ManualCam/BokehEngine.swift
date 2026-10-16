import CoreImage
import Vision

/// 虚化合成。iPhone 光圈物理固定，景深是算出来的：
/// 1. 有双摄/三摄深度数据时，用系统人像同款的 CIDepthBlurEffect，按模拟 f 值渲染（效果最好）
/// 2. 没有深度时，用 Vision 抠出前景主体（人、宠物、物体都行），背景按 f 值做模糊再合回去
enum BokehEngine {

    enum Method {
        case depth, subjectMask, none

        var name: String {
            switch self {
            case .depth: return "深度虚化"
            case .subjectMask: return "主体识别虚化"
            case .none: return "未识别到主体"
            }
        }
    }

    /// - Parameters:
    ///   - data: 照片文件数据（深度图如果有，嵌在里面）
    ///   - raw: 未处理的原图（传感器方向）
    ///   - aperture: 模拟 f 值，越小背景越虚
    ///   - focusPoint: 点击对焦的设备坐标（0~1，左上原点，传感器方向），nil 表示让系统自己找主体
    ///   - orientation: 拍摄时手机朝向对应的图像方向（竖拍 .right，横拍 .up/.down）
    /// - Returns: 已转正的结果图和实际用到的方法
    static func render(data: Data, raw: CIImage, aperture: Float,
                       focusPoint: CGPoint?, orientation: CGImagePropertyOrientation,
                       context: CIContext) -> (CIImage, Method) {
        let upright = raw.oriented(orientation)

        if let depthResult = renderWithDepth(data: data, raw: raw, aperture: aperture,
                                             focusPoint: focusPoint, orientation: orientation, context: context) {
            return (depthResult, .depth)
        }
        if let maskResult = renderWithSubjectMask(upright, aperture: aperture) {
            return (maskResult, .subjectMask)
        }
        return (upright, .none)
    }

    // MARK: - 深度路径

    private static func renderWithDepth(data: Data, raw: CIImage, aperture: Float,
                                        focusPoint: CGPoint?, orientation: CGImagePropertyOrientation,
                                        context: CIContext) -> CIImage? {
        // 照片里没有深度图时这里返回 nil，走 Vision 兜底
        guard let filter = context.depthBlurEffectFilter(forImageData: data, options: [:]) else { return nil }
        filter.setValue(aperture, forKey: "inputAperture")

        if let p = focusPoint {
            // 设备坐标是左上原点，Core Image 是左下原点，需要翻转 y；对焦框取画面 10% 见方
            let side: CGFloat = 0.1
            let rect = CIVector(cgRect: CGRect(x: max(0, p.x - side / 2),
                                               y: max(0, 1 - p.y - side / 2),
                                               width: side, height: side))
            filter.setValue(rect, forKey: "inputFocusRect")
        }

        guard let output = filter.outputImage else { return nil }
        // depthBlurEffectFilter 是否已按照片里的 EXIF 方向（竖拍 = .right）转过不好保证：
        // 宽高和原图一致说明还是传感器方向；宽高互换说明它已经转了 .right，先转回传感器方向。再按实际朝向转正
        let sameOrientation = (output.extent.width > output.extent.height) == (raw.extent.width > raw.extent.height)
        let sensor = sameOrientation ? output : output.oriented(.left)
        return sensor.oriented(orientation)
    }

    // MARK: - 主体识别路径

    private static func renderWithSubjectMask(_ image: CIImage, aperture: Float) -> CIImage? {
        guard let subject = subjectMask(for: image, feather: image.extent.width * 0.004) else { return nil }
        let background = subject.applyingFilter("CIColorInvert")

        // f/1.4 时模糊半径约为画面宽度的 1.5%，与 f 值成反比
        let radius = blurRadius(for: image, aperture: aperture)
        let blurred = image.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": background.clampedToExtent(),
                kCIInputRadiusKey: radius
            ])
            .cropped(to: image.extent)

        // 主体用原图（完全清晰），背景用模糊图，避免模糊把背景色晕进主体边缘
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: subject
        ])
    }

    private static func blurRadius(for image: CIImage, aperture: Float) -> CGFloat {
        image.extent.width * 0.015 * CGFloat(1.4 / aperture)
    }

    // MARK: - 主体掩码（拍后合成和实时预览共用）

    /// 用 Vision 识别前景主体（人、宠物、物体），返回灰度掩码（RGB 相同，1 = 主体），坐标和 image 一致。
    /// - Parameters:
    ///   - uprightOrientation: image 要怎么转才是正的。Vision 对"站着"的主体识别率更高，传感器方向的预览帧要传 .right
    ///   - maxSide: 识别前先缩到这个边长以内（实时预览用小图提速，掩码再放大回原尺寸，边缘本来就要羽化）
    ///   - feather: 羽化半径（像素），避免主体轮廓像剪纸
    static func subjectMask(for image: CIImage,
                            uprightOrientation: CGImagePropertyOrientation = .up,
                            maxSide: CGFloat = .greatestFiniteMagnitude,
                            feather: CGFloat) -> CIImage? {
        let extent = image.extent
        let scale = min(1, maxSide / max(extent.width, extent.height))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let upright = small.oriented(uprightOrientation)

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: upright, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances,
                                                                       from: handler) else { return nil }

        var mask = CIImage(cvPixelBuffer: buffer)
        // 掩码和识别用的图尺寸不一致时拉伸对齐
        if mask.extent.size != upright.extent.size {
            mask = mask.transformed(by: CGAffineTransform(scaleX: upright.extent.width / mask.extent.width,
                                                          y: upright.extent.height / mask.extent.height))
        }
        // 转回原图方向、放大回原尺寸、移回原坐标
        mask = mask.oriented(uprightOrientation.inverse)
        mask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        // 单通道掩码统一展开成灰度 RGB（CIMaskedVariableBlur 读绿通道，单通道图绿通道可能是 0）
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        return mask.clampedToExtent()
            .applyingGaussianBlur(sigma: feather)
            .cropped(to: extent)
    }

    /// 实时预览用的轻量虚化：整帧高斯模糊再按主体掩码合回（比拍后合成的可变模糊便宜很多，效果近似）
    static func previewBlur(_ image: CIImage, mask: CIImage, aperture: Float) -> CIImage {
        guard mask.extent == image.extent else { return image }
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: blurRadius(for: image, aperture: aperture) * 0.5)
            .cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred,
            kCIInputMaskImageKey: mask
        ])
    }
}

extension CGImagePropertyOrientation {
    /// 反方向（转回去）
    var inverse: CGImagePropertyOrientation {
        switch self {
        case .right: return .left
        case .left: return .right
        case .rightMirrored: return .rightMirrored
        case .leftMirrored: return .leftMirrored
        default: return self
        }
    }
}
