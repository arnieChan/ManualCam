import Foundation

/// 单反式 1/3 档刻度：快门 / ISO / 模拟光圈都按相机拨盘的标准挡位跳，而不是连续数值。
/// 实际可用范围由当前镜头硬件决定，用 `stops(in:)` 裁剪。
enum ExposureStops {

    /// 快门 1/3 档（秒）。iPhone 单帧硬件上限通常在 1/3s~1s 之间，更长的效果交给「慢门」多帧合成
    static let shutter: [Float] = [
        1.0/8000, 1.0/6400, 1.0/5000, 1.0/4000, 1.0/3200, 1.0/2500, 1.0/2000, 1.0/1600,
        1.0/1250, 1.0/1000, 1.0/800, 1.0/640, 1.0/500, 1.0/400, 1.0/320, 1.0/250,
        1.0/200, 1.0/160, 1.0/125, 1.0/100, 1.0/80, 1.0/60, 1.0/50, 1.0/40,
        1.0/30, 1.0/25, 1.0/20, 1.0/15, 1.0/13, 1.0/10, 1.0/8, 1.0/6,
        1.0/5, 1.0/4, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0
    ]

    /// ISO 1/3 档
    static let iso: [Float] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800
    ]

    /// 虚化用的模拟光圈（f 值）。iPhone 物理光圈固定，这里只决定后期合成的虚化强度
    static let aperture: [Float] = [
        1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6, 6.3, 7.1, 8.0,
        9.0, 10, 11, 13, 14, 16
    ]

    /// 慢门合成时长（秒）
    static let longExposure: [Double] = [1, 2, 4, 8, 15, 30]

    /// 取出落在硬件范围内的挡位；范围两端不在表里时补上端点，保证滑杆能推到硬件极限
    static func stops(_ table: [Float], in range: ClosedRange<Float>) -> [Float] {
        // 留 1% 余量，避免 1/8000 这种浮点值因为精度被误判出界
        var result = table.filter { $0 >= range.lowerBound * 0.99 && $0 <= range.upperBound * 1.01 }
            .map { min(max($0, range.lowerBound), range.upperBound) }
        if result.first.map({ $0 > range.lowerBound * 1.01 }) ?? true { result.insert(range.lowerBound, at: 0) }
        if result.last.map({ $0 < range.upperBound * 0.99 }) ?? true { result.append(range.upperBound) }
        return result
    }

    /// 在对数空间里找最接近的挡位下标（曝光是按倍数感知的，线性距离会偏向长快门）
    static func nearestIndex(of value: Float, in stops: [Float]) -> Int {
        guard !stops.isEmpty else { return 0 }
        let target = log2(max(value, .leastNonzeroMagnitude))
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, s) in stops.enumerated() {
            let d = abs(log2(s) - target)
            if d < bestDistance { best = i; bestDistance = d }
        }
        return best
    }

    /// 快门显示：≥0.3s 用秒，其余按相机习惯显示 1/N（N 取整，1/8000 而不是 1/7999）
    static func shutterLabel(_ seconds: Float) -> String {
        if seconds >= 0.3 {
            return seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
        }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    static func apertureLabel(_ f: Float) -> String {
        f >= 10 ? "f/\(Int(f))" : String(format: "f/%.1f", f)
    }
}
