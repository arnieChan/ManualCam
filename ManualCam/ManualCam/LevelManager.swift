import CoreMotion
import Combine

/// 水平仪：用重力向量算出手机相对竖直持握的左右倾斜角度（度），
/// 0° = 竖持端平，正负号对应向右/向左倾斜；横持时约 ±90°，水平仪显示的是相对最近横/竖姿态的偏差。
final class LevelManager: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0

    private let motionManager = CMMotionManager()

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let g = motion.gravity
            // 竖持手机时，端平对应重力沿设备 -Y 方向；绕屏幕法线的倾斜角由 x/y 分量的反正切给出
            self?.rollDegrees = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
}
