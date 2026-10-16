import Photos
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// 拍摄格式
enum PhotoFormat: String, CaseIterable, Identifiable, Codable {
    /// 调色后的 HEIF（带完整 EXIF）
    case heif
    /// 传感器原始 Bayer RAW（DNG）+ 调色 HEIF 预览，任何支持 RAW 的机型都能用
    case raw
    /// Apple ProRAW（DNG，Pro 机型，可到 4800 万像素）+ 调色 HEIF 预览
    case proRAW

    var id: String { rawValue }

    var name: String {
        switch self {
        case .heif: return "HEIF"
        case .raw: return "RAW"
        case .proRAW: return "ProRAW"
        }
    }
}

/// 照片编码与写入相册
enum PhotoSaver {

    /// 把调色后的图编码成 HEIF，并把原片的 EXIF / TIFF / GPS 等元数据写回去
    /// （之前用 UIImage 存相册，ISO、快门、镜头信息全部丢失）
    static func heifData(from cgImage: CGImage,
                         orientation: CGImagePropertyOrientation,
                         metadata: [String: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.heic.identifier as CFString, 1, nil) else { return nil }

        var properties = metadata
        properties[kCGImagePropertyOrientation as String] = orientation.rawValue
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = orientation.rawValue
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        // 调色/合成后尺寸可能变了（慢门会降采样），像素尺寸以实际图为准
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
        exif[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
        properties[kCGImagePropertyExifDictionary as String] = exif
        // 顶层像素尺寸由编码器按实际图写入，原片的值去掉
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 合成照片（慢门）没有相机给的元数据，自己补一份：总时长记为曝光时间
    static func syntheticMetadata(exposureSeconds: Double, iso: Float, comment: String) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let now = formatter.string(from: Date())
        return [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifExposureTime as String: exposureSeconds,
                kCGImagePropertyExifISOSpeedRatings as String: [Int(iso.rounded())],
                kCGImagePropertyExifDateTimeOriginal as String: now,
                kCGImagePropertyExifDateTimeDigitized as String: now
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: UIDevice.current.model,
                kCGImagePropertyTIFFSoftware as String: "ManualCam",
                kCGImagePropertyTIFFDateTime as String: now,
                // 备注写在 TIFF ImageDescription：EXIF UserComment 有编码头，ImageIO 写中文会被截断（实测）
                kCGImagePropertyTIFFImageDescription as String: comment
            ]
        ]
    }

    /// 写入相册。有 RAW 时作为同一张照片的 RAW+HEIF 组合保存（相册里显示 RAW 角标，Lightroom 等可直接读 DNG）
    static func save(photo: Data, raw: Data? = nil, completion: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion("没有相册写入权限，请在设置中允许")
                return
            }
            var assetID: String?
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: photo, options: nil)
                if let raw {
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "com.adobe.raw-image"
                    request.addResource(with: .alternatePhoto, data: raw, options: options)
                }
                assetID = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                // 记下本 App 拍的照片，App 内相册只显示这些
                if success, let assetID {
                    DispatchQueue.main.async { CaptureLibrary.shared.add(assetID) }
                }
                completion(success ? nil : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            }
        }
    }
}
