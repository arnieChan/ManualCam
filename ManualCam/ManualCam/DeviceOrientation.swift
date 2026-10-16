import CoreMotion
import ImageIO
import SwiftUI

/// 手机的物理朝向。界面固定竖屏（和系统相机一样，取景器不跟着转），
/// 但拍出来的照片方向、按钮图标要跟着手机实际怎么拿来走
enum PhysicalOrientation: Equatable {
    /// 正常竖持
    case portrait
    /// 顶部朝左横持（Home 指示条在右）
    case landscapeLeft
    /// 顶部朝右横持（Home 指示条在左）
    case landscapeRight
    /// 倒持
    case portraitUpsideDown

    /// 后置摄像头传感器画面要怎么转才是正的（写进照片的方向）
    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        case .portraitUpsideDown: return .left
        }
    }

    /// 图标、缩略图要转多少度才能在手机横过来时保持正向
    var iconRotation: Angle {
        switch self {
        case .portrait: return .zero
        case .landscapeLeft: return .degrees(90)
        case .landscapeRight: return .degrees(-90)
        case .portraitUpsideDown: return .degrees(180)
        }
    }

    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        }
    }
}

/// 用重力方向判断手机朝向。不用 UIDevice.orientation：用户开了"竖排方向锁定"时它永远报竖屏，
/// 而重力传感器不受影响（系统相机也是这么做的）
final class OrientationTracker {
    private let motion = CMMotionManager()
    private(set) var orientation: PhysicalOrientation = .portrait
    var onChange: ((PhysicalOrientation) -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.2
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            // 手机平放（屏幕朝天/朝地）时 x、y 都很小，保持上一次的朝向
            guard max(abs(g.x), abs(g.y)) > 0.5 else { return }
            // 迟滞：主轴要明显占优才切换，避免 45° 附近来回跳
            let next: PhysicalOrientation
            if abs(g.x) > abs(g.y) + 0.2 {
                next = g.x < 0 ? .landscapeLeft : .landscapeRight
            } else if abs(g.y) > abs(g.x) + 0.2 {
                next = g.y < 0 ? .portrait : .portraitUpsideDown
            } else {
                return
            }
            if next != self.orientation {
                self.orientation = next
                self.onChange?(next)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}

/// 图标跟随手机朝向旋转（带动画），用于快门旁缩略图、顶部图标等
struct RotatesWithDevice: ViewModifier {
    let orientation: PhysicalOrientation

    func body(content: Content) -> some View {
        content
            .rotationEffect(orientation.iconRotation)
            .animation(.easeInOut(duration: 0.25), value: orientation)
    }
}

extension View {
    func rotatesWithDevice(_ orientation: PhysicalOrientation) -> some View {
        modifier(RotatesWithDevice(orientation: orientation))
    }
}
