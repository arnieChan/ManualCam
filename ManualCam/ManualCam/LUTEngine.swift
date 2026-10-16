import CoreImage
import Foundation

// MARK: - 3D LUT 数据结构

/// 一个 RGB 三维查找表。data 为 float32 RGBA 排列，索引规则与 CIColorCube 一致：
/// offset = ((b * n + g) * n + r) * 4，即 red 变化最快（和 .cube 文件行序相同）。
struct CubeLUT {
    let size: Int
    let data: Data   // size^3 * 4 个 Float32

    /// 用 CIColorCube 应用到图像（iOS 11+，GPU 加速，单帧 <1ms）
    func apply(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorCube") else { return image }
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}

// MARK: - .cube 文件解析

enum LUTParseError: Error, LocalizedError {
    case missingSize, badDataCount, badLine

    var errorDescription: String? {
        switch self {
        case .missingSize: return "文件里没有 LUT_3D_SIZE 声明"
        case .badDataCount: return "LUT 数据行数与声明的尺寸不符"
        case .badLine: return "存在无法解析的数据行"
        }
    }
}

enum CubeLUTParser {

    /// 解析行业标准 .cube 文件（Adobe / DaVinci Resolve 均可导出此格式）
    static func parse(text: String) throws -> CubeLUT {
        var size = 0
        var values: [Float] = []
        values.reserveCapacity(64 * 64 * 64 * 3)

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("LUT_3D_SIZE") {
                let parts = line.split(separator: " ")
                guard parts.count == 2, let n = Int(parts[1]), n >= 2, n <= 256 else {
                    throw LUTParseError.missingSize
                }
                size = n
                continue
            }
            // 跳过 TITLE / DOMAIN_MIN / DOMAIN_MAX 等元信息
            if line.contains("_") && !line.first!.isNumber && line.first != "-" && line.first != "." { continue }

            let comps = line.split(separator: " ").compactMap { Float($0) }
            guard comps.count == 3 else { throw LUTParseError.badLine }
            values.append(contentsOf: comps)
        }

        guard size > 0 else { throw LUTParseError.missingSize }
        guard values.count == size * size * size * 3 else { throw LUTParseError.badDataCount }

        // 展开为 RGBA float32
        var rgba: [Float] = []
        rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(values[i]); rgba.append(values[i + 1]); rgba.append(values[i + 2]); rgba.append(1.0)
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, data: data)
    }
}

// MARK: - LUT 烘焙器：把任意 CoreImage 滤镜链固化成 LUT

enum LUTBaker {

    /// 让一张"单位立方体"图像穿过滤镜链，输出结果就是等效 LUT。
    /// 好处：预览时只用一次 CIColorCube，比串整条滤镜链快得多；
    /// 且烘焙结果可导出为 .cube 分享。
    static func bake(size: Int = 64, chain: (CIImage) -> CIImage) -> CubeLUT {
        // 构造单位立方体位图：宽 n*n、高 n，像素 (x, y) 对应 b = y, g = x/n, r = x%n
        var pixels = [Float](repeating: 0, count: size * size * size * 4)
        let denom = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let i = ((b * size + g) * size + r) * 4
                    pixels[i] = Float(r) / denom
                    pixels[i + 1] = Float(g) / denom
                    pixels[i + 2] = Float(b) / denom
                    pixels[i + 3] = 1.0
                }
            }
        }

        let inData = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let bitmap = CIImage(bitmapData: inData,
                             bytesPerRow: size * size * 4 * MemoryLayout<Float>.size,
                             size: CGSize(width: size * size, height: size),
                             format: .RGBAf,
                             colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)

        let processed = chain(bitmap)

        // 渲染回 float 位图
        var outPixels = [Float](repeating: 0, count: size * size * size * 4)
        let context = CIContext()
        context.render(processed,
                       toBitmap: &outPixels,
                       rowBytes: size * size * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: size * size, height: size),
                       format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedSRGB)!)

        let outData = outPixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(size: size, data: outData)
    }
}

// MARK: - 用户导入 LUT 管理（持久化到 Documents/LUTs）

final class CustomLUTStore: ObservableObject {
    static let shared = CustomLUTStore()

    @Published private(set) var items: [ToneItem] = []
    private var luts: [String: CubeLUT] = [:]

    private var storeDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { loadFromDisk() }

    /// 从文件选择器导入 .cube（需要处理安全作用域）
    func importLUT(from url: URL) throws -> ToneItem {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let text = try String(contentsOf: url, encoding: .utf8)
        let lut = try CubeLUTParser.parse(text: text)

        let id = UUID().uuidString
        let name = url.deletingPathExtension().lastPathComponent
        let dest = storeDir.appendingPathComponent("\(id).cube")
        try text.write(to: dest, atomically: true, encoding: .utf8)

        let item = ToneItem(id: "custom-\(id)", name: name)
        luts[item.id] = lut
        items.append(item)
        return item
    }

    func lut(for id: String) -> CubeLUT? { luts[id] }

    private func loadFromDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "cube" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let lut = try? CubeLUTParser.parse(text: text) else { continue }
            let uuidPart = file.deletingPathExtension().lastPathComponent
            let item = ToneItem(id: "custom-\(uuidPart)", name: uuidPart)
            luts[item.id] = lut
            items.append(item)
        }
    }
}
