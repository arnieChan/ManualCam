import AVFoundation
import CoreImage
import UIKit
import Photos

enum CameraAuthorizationState {
    case notDetermined, authorized, denied
}

/// RGB 直方图数据（各 32 个桶，已归一化到 0~1）
struct HistogramData: Equatable {
    var r: [Float] = [Float](repeating: 0, count: 32)
    var g: [Float] = [Float](repeating: 0, count: 32)
    var b: [Float] = [Float](repeating: 0, count: 32)
}

/// 曝光档位（由 ISO / 快门两个自动开关组合而成）
enum ExposureProgram {
    case program, shutterPriority, isoPriority, manual

    var badge: String {
        switch self {
        case .program: return "P"
        case .shutterPriority: return "S"
        case .isoPriority: return "ISO"
        case .manual: return "M"
        }
    }
}

/// 驱动模式（相机的"单拍 / 连拍 / 自拍 / 间隔"）
enum DriveMode: String, CaseIterable, Identifiable, Codable {
    case single, burst, timer3, timer10, interval

    var id: String { rawValue }

    var name: String {
        switch self {
        case .single: return "单拍"
        case .burst: return "连拍"
        case .timer3: return "自拍 3 秒"
        case .timer10: return "自拍 10 秒"
        case .interval: return "间隔拍摄"
        }
    }

    var symbol: String {
        switch self {
        case .single: return "square"
        case .burst: return "square.stack.3d.down.right"
        case .timer3: return "3.circle"
        case .timer10: return "10.circle"
        case .interval: return "timer"
        }
    }
}

/// 拍摄模式
enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case photo, longExposure, bokeh, bracket

    var id: String { rawValue }

    var name: String {
        switch self {
        case .photo: return "照片"
        case .longExposure: return "慢门"
        case .bokeh: return "虚化"
        case .bracket: return "包围"
        }
    }
}

/// 相机核心：AVCaptureSession 管理 + 全手动参数控制 + LUT 色调管线
/// + 峰值对焦 + 实时直方图 + 拍照保存
final class CameraManager: NSObject, ObservableObject {

    // MARK: - 发布给 UI 的状态

    @Published var previewImage: CGImage?
    @Published var lastShot: UIImage?
    @Published var authorizationState: CameraAuthorizationState = .notDetermined
    @Published var errorMessage: String?
    @Published var histogram = HistogramData()

    // MARK: - 手动参数（修改即生效）

    /// 当前色调 ID（内置预设或 custom- 开头的导入 LUT）
    @Published var toneID: String = ToneEngine.standardID

    /// 峰值对焦开关：合焦区域叠加红色高亮
    @Published var focusPeakingEnabled = false
    /// 直方图开关
    @Published var histogramEnabled = true
    /// 斑马纹开关：过曝区域叠加条纹提示
    @Published var zebraEnabled = false

    /// 对焦位置 0.0（近）~ 1.0（远）
    @Published var lensPosition: Float = 0.5 { didSet { applyFocus() } }
    @Published var autoFocus = true { didSet { applyFocus() } }

    /// ISO 感光度
    @Published var iso: Float = 100 { didSet { applyExposure(); syncCaptureControls() } }
    /// 快门速度（秒），如 1/120
    @Published var shutterSeconds: Float = 1.0 / 125.0 { didSet { applyExposure(); syncCaptureControls() } }
    /// ISO / 快门各自独立的自动开关，组合出单反的四个曝光档：
    /// 都自动 = P 档；只锁快门 = S 档（快门优先，自动配 ISO）；只锁 ISO = ISO 优先（自动配快门）；都锁 = M 档
    @Published var autoISO = true { didSet { applyExposure(); syncCaptureControls() } }
    @Published var autoShutter = true { didSet { applyExposure(); syncCaptureControls() } }

    var exposureProgram: ExposureProgram {
        switch (autoISO, autoShutter) {
        case (true, true): return .program
        case (true, false): return .shutterPriority
        case (false, true): return .isoPriority
        case (false, false): return .manual
        }
    }

    /// 相机实际在用的 ISO / 快门（自动的那一项靠它显示当前测光结果）
    @Published private(set) var meteredISO: Float = 100
    @Published private(set) var meteredShutter: Float = 1.0 / 125.0
    /// 测光表读数（EV）：M 档下当前参数相对正确曝光的偏差，正数 = 过曝
    @Published private(set) var meterOffset: Float = 0

    // MARK: - 拍摄模式：照片 / 慢门 / 虚化

    @Published var captureMode: CaptureMode = .photo {
        didSet {
            if captureMode != oldValue { captureModeChanged(from: oldValue) }
            syncCaptureControls()
        }
    }

    /// 慢门合成时长（秒）和合成方式
    @Published var longExposureSeconds: Double = 4
    @Published var longExposureBlend: LongExposureBlend = .average
    /// 慢门手持对齐（三脚架上可关掉，省电也更快）
    @Published var longExposureHandheld = true
    /// 慢门进行中：nil = 空闲；0~1 = 合成进度
    @Published private(set) var longExposureProgress: Double?
    /// 慢门按下后的防抖倒计时（秒），nil = 不在倒计时
    @Published private(set) var countdown: Int?

    /// 驱动模式。连拍、间隔只在照片模式可用；自拍在照片/虚化/包围可用；慢门自带 2 秒延时
    @Published var driveMode: DriveMode = .single
    /// 间隔拍摄：间隔秒数、总张数（0 = 不限，按快门停止）、是否顺便合成星轨
    @Published var intervalSeconds: Double = 5
    @Published var intervalCount: Int = 30
    @Published var intervalStarTrail = false
    /// 间隔拍摄进行中已拍张数（nil = 未在拍）
    @Published private(set) var intervalShotsTaken: Int?
    /// 连拍进行中已拍张数（nil = 未在连拍）
    @Published private(set) var burstShotsTaken: Int?
    static let burstLimit = 30

    var availableDriveModes: [DriveMode] {
        switch captureMode {
        case .photo: return DriveMode.allCases
        case .bokeh, .bracket: return [.single, .timer3, .timer10]
        case .longExposure: return [.single]
        }
    }

    /// 当前模式下实际生效的驱动方式（选了连拍再切到虚化，就按单拍处理）
    var effectiveDriveMode: DriveMode {
        availableDriveModes.contains(driveMode) ? driveMode : .single
    }

    /// 包围曝光档距（EV）和是否合成 HDR
    @Published var bracketSpread: Float = 1
    @Published var bracketMergeHDR = true

    /// 虚化的模拟光圈 f 值
    @Published var apertureF: Float = 2.8 { didSet { syncCaptureControls() } }
    /// 当前镜头组是否能拍深度（false 时虚化走 Vision 主体识别）
    @Published private(set) var depthAvailable = false
    /// 拍摄后正在合成（虚化/慢门）
    @Published private(set) var isProcessing = false
    /// 拍完后的短提示（如"深度虚化 f/2.8"），显示一会儿自动消失
    @Published var toast: String?

    /// 拍摄格式（HEIF / RAW / ProRAW），只在「照片」模式生效
    @Published var photoFormat: PhotoFormat = .heif {
        didSet { if photoFormat != oldValue { reconfigurePhotoOutput() } }
    }
    /// 手机物理朝向（界面固定竖屏，照片方向和图标跟着它走）
    @Published private(set) var physicalOrientation: PhysicalOrientation = .portrait
    private let orientationTracker = OrientationTracker()
    /// 拍照时写进照片的方向
    var captureOrientation: CGImagePropertyOrientation { physicalOrientation.imageOrientation }

    /// 相机控制键拨盘展开中（此时收起 App 自己的参数面板）
    @Published var controlsOverlayActive = false

    /// 当前镜头支持的格式（随机型、镜头变化）
    @Published private(set) var supportedFormats: [PhotoFormat] = [.heif]

    /// 白平衡色温（K）
    @Published var temperature: Float = 5600 { didSet { applyWhiteBalance() } }
    @Published var autoWhiteBalance = true { didSet { applyWhiteBalance() } }
    /// 色调（绿 ↔ 品红），负数偏绿、正数偏品红，和 Lightroom 的 Tint 同向
    @Published var tint: Float = 0 { didSet { applyWhiteBalance() } }

    /// 曝光补偿（EV）：P / S / ISO 优先档生效（偏移测光目标）；M 档 ISO+快门全手动，EV 不起作用，改看测光表读数
    @Published var exposureBias: Float = 0 { didSet { applyExposureBias() } }

    /// 硬件允许的参数范围（配置完成后更新，供 UI 滑杆使用）
    @Published private(set) var isoRange: ClosedRange<Float> = 25...3200
    @Published private(set) var shutterRange: ClosedRange<Float> = 1.0 / 8000.0...1.0
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = -2...2

    /// 数字变焦（双指捏合触发），范围随当前镜头变化
    @Published var zoomFactor: CGFloat = 1.0 { didSet { if !zoomDrivenBySystemControl { applyZoom(zoomFactor) } } }
    /// 相机控制键的系统变焦拨盘已经直接改了设备，只同步显示，不再回写（否则会被 8x 上限拉回）
    var zoomDrivenBySystemControl = false
    @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1.0...1.0

    /// 当前物理镜头 + 本机可用的物理镜头列表（超广角/广角/长焦，随机型而定）
    @Published private(set) var currentLensType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    @Published private(set) var availableLensTypes: [AVCaptureDevice.DeviceType] = []

    // MARK: - 内部

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "manualcam.session")
    private let videoQueue = DispatchQueue(label: "manualcam.video")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private(set) var device: AVCaptureDevice?
    /// 相机控制键拨盘引用（iOS 18 的 CaptureControlSet，类型擦除以兼容 iOS 17）
    var captureControlSet: Any?
    /// 本机所有可用物理镜头（只在 sessionQueue 上读写，避免和 UI 线程数据竞争）
    private var lensDevices: [AVCaptureDevice] = []
    private let ciContext = CIContext()
    private var frameCounter = 0

    /// 慢门合成器（只在 videoQueue 上访问）
    private var stacker: LongExposureStacker?
    /// 最近一帧未调色的预览画面（只在 videoQueue 上读写），点选白平衡时取样用
    private var lastRawFrame: CIImage?
    /// 虚化实时预览：最近一次识别出的主体掩码（videoQueue 上读写）。识别比较慢，放在 maskQueue 隔几帧做一次，
    /// 中间的帧沿用上一次的掩码；主体移动时掩码会略微滞后
    private var previewSubjectMask: CIImage?
    private var maskInFlight = false
    private let maskQueue = DispatchQueue(label: "manualcam.mask", qos: .userInitiated)
    /// 进入虚化模式前用的物理镜头，退出时切回
    private var lensBeforeBokeh: AVCaptureDevice.DeviceType?
    private var countdownToken = UUID()
    /// 慢门 / 星轨开始时的手机朝向
    private var longExposureOrientation: CGImagePropertyOrientation = .right
    private var starTrailOrientation: CGImagePropertyOrientation = .right
    /// 倒计时结束后要做的事（自拍拍照 / 慢门开始合成）
    private var countdownAction: (() -> Void)?
    private var intervalTimer: Timer?
    /// 星轨：间隔拍摄的每张照片逐张取最亮叠加（只在 starTrailQueue 上访问）
    private let starTrailQueue = DispatchQueue(label: "manualcam.startrail")
    private var starTrailAccumulator: CIImageAccumulator?
    private var starTrailActive = false
    private var starTrailFrames = 0
    /// 开启 ProRAW 后 availableRawPhotoPixelFormatTypes 可能只剩 ProRAW，Bayer RAW 支持情况在关闭时记下来
    private var bayerRAWSupported = false
    /// 最近一次点击对焦的位置（设备坐标），虚化时作为合焦点
    private var lastFocusPoint: CGPoint?
    /// 每次拍照时的模式快照，按 settings.uniqueID 取回（拍照回调在别的线程，期间用户可能已切模式）
    private var pendingShots: [Int64: PendingShot] = [:]
    private let pendingLock = NSLock()

    /// 一次拍摄的上下文。RAW 拍摄时相机会分两次回调（DNG 原片 + 处理后的 HEIF），两份数据都到齐后一起存
    private final class PendingShot {
        let mode: CaptureMode
        let format: PhotoFormat
        let aperture: Float
        let focusPoint: CGPoint?
        let toneID: String
        var rawData: Data?
        var photoData: Data?
        /// 包围曝光：档距、是否合成，以及收到的各帧（未调色原图 + 元数据，按序号排）
        var bracketSpread: Float = 0
        var bracketMerge = false
        var bracketFrames: [(sequence: Int, image: CIImage, metadata: [String: Any])] = []
        var isBurst = false
        var starTrail = false
        /// 按下快门那一刻的手机朝向（拍照回调到达时用户可能已经转了手机）
        var orientation: CGImagePropertyOrientation = .right

        init(mode: CaptureMode, format: PhotoFormat, aperture: Float, focusPoint: CGPoint?, toneID: String) {
            self.mode = mode
            self.format = format
            self.aperture = aperture
            self.focusPoint = focusPoint
            self.toneID = toneID
        }
    }

    /// 按 超广角 → 广角 → 长焦 排序，符合用户认知的从小到大
    private static let lensPriority: [AVCaptureDevice.DeviceType] = [
        .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera
    ]

    // MARK: - 启动

    func start() {
        orientationTracker.onChange = { [weak self] orientation in
            self?.physicalOrientation = orientation
        }
        orientationTracker.start()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorizationState = granted ? .authorized : .denied
                    if granted { self.configureSession() }
                }
            }
        default:
            authorizationState = .denied
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            let lenses = self.discoverLenses()
            guard let device = lenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? lenses.first,
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.errorMessage = "无法打开后置摄像头（模拟器没有相机，请用真机运行）" }
                return
            }
            self.device = device
            self.lensDevices = lenses
            self.session.addInput(input)

            // 实时预览帧输出（走 LUT 色调管线）
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            // 拍照输出
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.configurePhotoOutput()
            if #available(iOS 18.0, *), self.session.supportsControls {
                self.session.setControlsDelegate(self, queue: .main)
            }
            self.configureCaptureControls()

            self.session.commitConfiguration()

            // 读取硬件参数范围
            self.publishRanges(for: device, lensType: device.deviceType)
            DispatchQueue.main.async {
                self.availableLensTypes = lenses.map(\.deviceType)
            }

            self.session.startRunning()
        }
    }

    /// 把当前镜头的硬件参数范围同步给 UI（ISO/快门/变焦/EV 滑杆都按它裁剪）
    private func publishRanges(for device: AVCaptureDevice, lensType: AVCaptureDevice.DeviceType,
                               zoom: CGFloat = 1.0) {
        let format = device.activeFormat
        let depth = photoOutput.isDepthDataDeliverySupported
        DispatchQueue.main.async {
            self.currentLensType = lensType
            self.isoRange = format.minISO...format.maxISO
            self.shutterRange = Float(CMTimeGetSeconds(format.minExposureDuration))...Float(CMTimeGetSeconds(format.maxExposureDuration))
            self.iso = max(self.isoRange.lowerBound, min(self.iso, self.isoRange.upperBound))
            self.shutterSeconds = max(self.shutterRange.lowerBound, min(self.shutterSeconds, self.shutterRange.upperBound))
            self.zoomRange = zoom...max(zoom, min(format.videoMaxZoomFactor, 8.0 * zoom))
            self.zoomFactor = zoom
            self.exposureBiasRange = device.minExposureTargetBias...device.maxExposureTargetBias
            // 换镜头只把 EV 夹回新范围，不清零（调用自定义档时切模式会换镜头，清零会冲掉档里存的 EV）
            self.exposureBias = max(self.exposureBiasRange.lowerBound, min(self.exposureBias, self.exposureBiasRange.upperBound))
            self.depthAvailable = depth
        }
    }

    /// 更换相机输入（物理镜头切换、进出虚化模式共用）。必须在 sessionQueue 上调用
    @discardableResult
    private func replaceInput(with newDevice: AVCaptureDevice, configure: (() -> Void)? = nil) -> Bool {
        guard newDevice.uniqueID != device?.uniqueID,
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return false }

        session.beginConfiguration()
        let oldInput = session.inputs.first as? AVCaptureDeviceInput
        if let oldInput { session.removeInput(oldInput) }
        guard session.canAddInput(newInput) else {
            if let oldInput, session.canAddInput(oldInput) { session.addInput(oldInput) }
            session.commitConfiguration()
            return false
        }
        session.addInput(newInput)
        device = newDevice
        configure?()
        configurePhotoOutput()
        configureCaptureControls()
        session.commitConfiguration()
        return true
    }

    /// 按当前镜头和所选格式配置拍照输出。必须在 sessionQueue、beginConfiguration/commitConfiguration 之间调用
    private func configurePhotoOutput() {
        guard let device else { return }
        // 输出上限放到传感器满像素，单张拍摄时再按格式选实际尺寸（见 makePhotoSettings）
        if let maxDims = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width < $1.width }) {
            photoOutput.maxPhotoDimensions = maxDims
        }
        if !photoOutput.isAppleProRAWEnabled {
            bayerRAWSupported = photoOutput.availableRawPhotoPixelFormatTypes
                .contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        }
        let proRAWSupported = photoOutput.isAppleProRAWSupported
        photoOutput.isAppleProRAWEnabled = proRAWSupported && photoFormat == .proRAW

        var formats: [PhotoFormat] = [.heif]
        if bayerRAWSupported { formats.append(.raw) }
        if proRAWSupported { formats.append(.proRAW) }
        DispatchQueue.main.async {
            self.supportedFormats = formats
            // 换到不支持当前格式的镜头时退回 HEIF
            if !formats.contains(self.photoFormat) { self.photoFormat = .heif }
        }
    }

    private func reconfigurePhotoOutput() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configurePhotoOutput()
            self.session.commitConfiguration()
        }
    }

    /// 新镜头重新应用一遍当前的手动对焦/曝光/白平衡，保持参数连续
    private func reapplyManualSettings() {
        applyFocus()
        applyExposure()
        applyWhiteBalance()
    }

    /// 扫描后置的超广角/广角/长焦镜头，按用户认知顺序排列
    private func discoverLenses() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Self.lensPriority, mediaType: .video, position: .back)
        return discovery.devices.sorted {
            (Self.lensPriority.firstIndex(of: $0.deviceType) ?? .max)
                < (Self.lensPriority.firstIndex(of: $1.deviceType) ?? .max)
        }
    }

    /// 每个镜头各自记住的对焦 / 曝光参数（白平衡跟场景走，不按镜头记）
    struct LensSettings: Codable {
        var autoFocus: Bool
        var lensPosition: Float
        var autoISO: Bool
        var iso: Float
        var autoShutter: Bool
        var shutterSeconds: Float
        var exposureBias: Float
    }

    private static let lensMemoryKey = "lensMemory.v1"

    private var lensMemory: [String: LensSettings] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.lensMemoryKey) else { return [:] }
            return (try? JSONDecoder().decode([String: LensSettings].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.lensMemoryKey)
            }
        }
    }

    /// 手动切换到指定物理镜头（超广角 / 广角 / 长焦）。
    /// 切走前记下当前镜头的对焦/曝光参数；切到的镜头如果以前用过，恢复它上次的参数，否则沿用当前参数
    func switchLens(to type: AVCaptureDevice.DeviceType) {
        guard type != currentLensType else { return }
        var memory = lensMemory
        memory[currentLensType.rawValue] = LensSettings(
            autoFocus: autoFocus, lensPosition: lensPosition, autoISO: autoISO, iso: iso,
            autoShutter: autoShutter, shutterSeconds: shutterSeconds, exposureBias: exposureBias)
        lensMemory = memory
        let remembered = memory[type.rawValue]

        sessionQueue.async { [weak self] in
            guard let self,
                  let newDevice = self.lensDevices.first(where: { $0.deviceType == type }),
                  self.replaceInput(with: newDevice) else { return }
            self.publishRanges(for: newDevice, lensType: type)
            self.reapplyManualSettings()
            // publishRanges 已经排进主队列（会按新镜头夹范围），这里排在它后面再恢复记忆值
            if let remembered {
                DispatchQueue.main.async { self.restore(remembered) }
            }
        }
    }

    private func restore(_ settings: LensSettings) {
        lensPosition = settings.lensPosition
        autoFocus = settings.autoFocus
        iso = max(isoRange.lowerBound, min(settings.iso, isoRange.upperBound))
        shutterSeconds = max(shutterRange.lowerBound, min(settings.shutterSeconds, shutterRange.upperBound))
        autoISO = settings.autoISO
        autoShutter = settings.autoShutter
        exposureBias = max(exposureBiasRange.lowerBound, min(settings.exposureBias, exposureBiasRange.upperBound))
    }

    // MARK: - 拍摄模式切换

    private func captureModeChanged(from old: CaptureMode) {
        if intervalShotsTaken != nil { stopInterval() }
        if burstShotsTaken != nil { shutterPressEnded() }
        countdown = nil
        countdownAction = nil
        if old == .longExposure { cancelLongExposure() }
        if captureMode == .bokeh { enterBokehMode() }
        if old == .bokeh { exitBokehMode() }
    }

    /// 虚化需要深度：当前物理镜头拍不了深度时，换成双摄/三摄虚拟镜头组（和系统人像模式一样），
    /// 同时把变焦设到主摄的切换点，取景范围和广角一致
    private func enterBokehMode() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.photoOutput.isDepthDataDeliverySupported,
               let depthDevice = Self.discoverDepthDevice() {
                self.lensBeforeBokeh = self.device?.deviceType
                self.replaceInput(with: depthDevice) {
                    self.enableDepthDelivery(true)
                }
                let wideZoom = depthDevice.virtualDeviceSwitchOverVideoZoomFactors
                    .first.map { CGFloat(truncating: $0) } ?? 1.0
                // 双摄（广角+长焦）的 1x 就是广角；含超广角的镜头组要推到第一个切换点才是广角
                let zoom: CGFloat = depthDevice.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
                    ? wideZoom : 1.0
                self.publishRanges(for: depthDevice, lensType: .builtInWideAngleCamera, zoom: zoom)
                self.reapplyManualSettings()
            } else {
                self.session.beginConfiguration()
                self.enableDepthDelivery(true)
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.depthAvailable = self.photoOutput.isDepthDataDeliveryEnabled }
            }
        }
    }

    private func exitBokehMode() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let previous = self.lensBeforeBokeh,
               let lens = self.lensDevices.first(where: { $0.deviceType == previous }) {
                self.lensBeforeBokeh = nil
                self.replaceInput(with: lens) { self.enableDepthDelivery(false) }
                self.publishRanges(for: lens, lensType: previous)
                self.reapplyManualSettings()
            } else {
                self.session.beginConfiguration()
                self.enableDepthDelivery(false)
                self.session.commitConfiguration()
            }
        }
    }

    /// 必须在 beginConfiguration/commitConfiguration 之间、新输入已加入后调用
    private func enableDepthDelivery(_ enabled: Bool) {
        photoOutput.isDepthDataDeliveryEnabled = enabled && photoOutput.isDepthDataDeliverySupported
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = enabled && photoOutput.isPortraitEffectsMatteDeliverySupported
    }

    /// 能拍深度的后置镜头组：优先广角+长焦（与系统人像一致），其次广角+超广角，再次三摄
    private static func discoverDepthDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        return types.lazy.compactMap { type in devices.first { $0.deviceType == type } }.first
    }

    // MARK: - 手动控制（AVFoundation 核心 API）

    private func applyFocus() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  let _ = try? device.lockForConfiguration() else { return }
            if self.autoFocus {
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
            } else if device.isFocusModeSupported(.locked) {
                // 手动对焦：lensPosition 0.0 = 最近对焦距离，1.0 = 无穷远
                device.setFocusModeLocked(lensPosition: self.lensPosition, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    private func applyExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  let _ = try? device.lockForConfiguration() else { return }
            let program = self.exposureProgram
            if program == .program || !device.isExposureModeSupported(.custom) {
                device.exposureMode = .continuousAutoExposure
            } else {
                // S / ISO 优先档：自动的那一项先沿用相机当前值，之后由 meteringStep 按测光持续修正
                let format = device.activeFormat
                let iso = self.autoISO ? device.iso : self.iso
                let clampedISO = max(format.minISO, min(iso, format.maxISO))
                let duration: CMTime
                if self.autoShutter {
                    duration = device.exposureDuration
                } else {
                    let seconds = max(self.shutterRange.lowerBound, min(self.shutterSeconds, self.shutterRange.upperBound))
                    duration = CMTime(seconds: Double(seconds), preferredTimescale: 1_000_000_000)
                }
                // iPhone 光圈物理固定，曝光只剩快门 + ISO 两个变量
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    /// 测光循环（约每秒 5 次，由预览帧驱动）：
    /// - 把相机实际 ISO/快门/测光偏差同步给 UI（自动项显示读数，M 档显示测光表）
    /// - S 档 / ISO 优先档：AVFoundation 没有半自动曝光模式，这里按 exposureTargetOffset 自己闭环修正自动的那一项。
    ///   custom 模式下 exposureTargetBias 只影响 exposureTargetOffset，所以 EV 补偿在半自动档同样生效
    private func meteringStep() {
        guard let device = device else { return }
        let offset = device.exposureTargetOffset
        let currentISO = device.iso
        let currentShutter = Float(CMTimeGetSeconds(device.exposureDuration))
        DispatchQueue.main.async {
            self.meteredISO = currentISO
            self.meteredShutter = currentShutter
            self.meterOffset = offset.isFinite ? offset : 0
        }

        let program = exposureProgram
        guard device.exposureMode == .custom,
              program == .shutterPriority || program == .isoPriority,
              stacker == nil,                    // 慢门合成中锁定曝光，避免亮度跳变
              offset.isFinite, abs(offset) > 0.1 else { return }

        // 阻尼 0.7：一步不修满，避免来回振荡
        let correction = pow(2, -offset * 0.7)
        let format = device.activeFormat
        guard (try? device.lockForConfiguration()) != nil else { return }
        if program == .shutterPriority {
            let newISO = max(format.minISO, min(currentISO * correction, format.maxISO))
            if abs(newISO - currentISO) / currentISO > 0.02 {
                device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration,
                                             iso: newISO, completionHandler: nil)
            }
        } else {
            let minS = Float(CMTimeGetSeconds(format.minExposureDuration))
            let maxS = Float(CMTimeGetSeconds(format.maxExposureDuration))
            let newShutter = max(minS, min(currentShutter * correction, maxS))
            if abs(newShutter - currentShutter) / currentShutter > 0.02 {
                device.setExposureModeCustom(duration: CMTime(seconds: Double(newShutter), preferredTimescale: 1_000_000_000),
                                             iso: AVCaptureDevice.currentISO, completionHandler: nil)
            }
        }
        device.unlockForConfiguration()
    }

    private func applyWhiteBalance() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  let _ = try? device.lockForConfiguration() else { return }
            if self.autoWhiteBalance {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            } else if device.isWhiteBalanceModeSupported(.locked) {
                let clamped = max(2500, min(self.temperature, 9000))
                let tint = max(-150, min(self.tint, 150))
                let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: clamped, tint: tint)
                var gains = device.deviceWhiteBalanceGains(for: tempAndTint)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = max(1.0, min(gains.redGain, maxGain))
                gains.greenGain = max(1.0, min(gains.greenGain, maxGain))
                gains.blueGain = max(1.0, min(gains.blueGain, maxGain))
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    /// 点选白平衡（灰卡）：取点击处一小块的平均色，把它校正成中性灰。
    /// 取样的是当前白平衡增益下的画面，所以新增益 = 旧增益 × (G/R, 1, G/B)，再换算回色温/色调显示在滑杆上
    func whiteBalance(at point: CGPoint) {
        videoQueue.async { [weak self] in
            guard let self, let frame = self.lastRawFrame else { return }
            let e = frame.extent
            let side = min(e.width, e.height) * 0.04
            // 设备坐标左上原点 → Core Image 左下原点
            let rect = CGRect(x: e.minX + point.x * e.width - side / 2,
                              y: e.minY + (1 - point.y) * e.height - side / 2,
                              width: side, height: side).intersection(e)
            let average = frame.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
            var px = [Float](repeating: 0, count: 4)
            // 输出到线性色彩空间：白平衡增益作用在线性光上
            self.ciContext.render(average, toBitmap: &px, rowBytes: 16,
                                  bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                  format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
            let (r, g, b) = (px[0], px[1], px[2])
            guard max(r, g, b) < 0.97 else {
                DispatchQueue.main.async { self.showToast("取样处过曝，换一块不那么亮的白/灰色区域") }
                return
            }
            guard min(r, g, b) > 0.005 else {
                DispatchQueue.main.async { self.showToast("取样处太暗，换一块更亮的白/灰色区域") }
                return
            }
            self.sessionQueue.async {
                guard let device = self.device else { return }
                let current = device.deviceWhiteBalanceGains
                var gains = AVCaptureDevice.WhiteBalanceGains(redGain: current.redGain * g / r,
                                                              greenGain: current.greenGain,
                                                              blueGain: current.blueGain * g / b)
                // 增益最小必须是 1，整体缩放不影响色彩比例
                let minGain = min(gains.redGain, gains.greenGain, gains.blueGain)
                gains.redGain /= minGain; gains.greenGain /= minGain; gains.blueGain /= minGain
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(gains.redGain, maxGain)
                gains.greenGain = min(gains.greenGain, maxGain)
                gains.blueGain = min(gains.blueGain, maxGain)
                let values = device.temperatureAndTintValues(for: gains)
                DispatchQueue.main.async {
                    self.temperature = max(2500, min(values.temperature, 9000))
                    self.tint = max(-150, min(values.tint, 150))
                    self.autoWhiteBalance = false
                    self.showToast("白平衡已校准：\(Int(self.temperature))K · 色调 \(Int(self.tint))")
                }
            }
        }
    }

    /// 曝光补偿：在 continuousAutoExposure/autoExpose 模式下对测光结果加偏移（EV），
    /// custom 模式（S/ISO 优先/M 档）下只影响 exposureTargetOffset，由 meteringStep 闭环把它修回 0
    private func applyExposureBias() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  let _ = try? device.lockForConfiguration() else { return }
            let clamped = max(self.exposureBiasRange.lowerBound, min(self.exposureBias, self.exposureBiasRange.upperBound))
            device.setExposureTargetBias(clamped, completionHandler: nil)
            device.unlockForConfiguration()
        }
    }

    /// 点击对焦 + 点测光：point 是设备坐标系（0,0 左上 ~ 1,1 右下，横向 home 键在右的坐标系），
    /// 由 View 层根据预览图实际显示区域换算后传入
    func focusAndExpose(at point: CGPoint) {
        lastFocusPoint = point
        let program = exposureProgram
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  let _ = try? device.lockForConfiguration() else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            // 只有 P 档才让点击接管测光；S/ISO/M 档下手动锁定的参数不能被点击冲掉
            if program == .program, device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
        }
    }

    /// 数字变焦（双指捏合驱动）：在当前物理镜头的传感器范围内裁切，非跨镜头
    private func applyZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device,
                  let _ = try? device.lockForConfiguration() else { return }
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 8.0)
            device.videoZoomFactor = max(1.0, min(factor, maxZoom))
            device.unlockForConfiguration()
        }
    }

    // MARK: - 拍照

    /// 快门（屏幕按钮单击、实体按键松开）
    func capture() {
        // 倒计时中再按 = 取消；间隔拍摄中再按 = 停止
        if countdown != nil {
            countdown = nil
            countdownAction = nil
            return
        }
        if intervalShotsTaken != nil {
            stopInterval()
            return
        }
        if captureMode == .longExposure {
            startOrFinishLongExposure()
            return
        }
        switch effectiveDriveMode {
        case .single, .burst: shoot()   // 连拍靠按住，单击只拍一张
        case .timer3: startCountdown(3) { [weak self] in self?.shoot() }
        case .timer10: startCountdown(10) { [weak self] in self?.shoot() }
        case .interval: startInterval()
        }
    }

    /// 实际拍一张（或一组包围）
    private func shoot(burst: Bool = false, starTrail: Bool = false) {
        switch captureMode {
        case .longExposure:
            return
        case .bracket:
            captureBracket()
        case .photo, .bokeh:
            guard !isProcessing else { return }
            let settings = makePhotoSettings()
            if burst {
                // 连拍要速度：跳过多帧降噪等耗时处理
                settings.photoQualityPrioritization = .speed
            }
            if captureMode == .bokeh, photoOutput.isDepthDataDeliveryEnabled {
                settings.isDepthDataDeliveryEnabled = true
                settings.embedsDepthDataInPhoto = true
                settings.isDepthDataFiltered = true
                if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                    settings.isPortraitEffectsMatteDeliveryEnabled = true
                    settings.embedsPortraitEffectsMatteInPhoto = true
                }
            }
            pendingLock.lock()
            let shot = PendingShot(
                mode: captureMode, format: settings.rawPhotoPixelFormatType == 0 ? .heif : photoFormat,
                aperture: apertureF, focusPoint: lastFocusPoint, toneID: toneID)
            shot.isBurst = burst
            shot.starTrail = starTrail
            shot.orientation = captureOrientation
            // RAW（DNG）不经过我们的编码，方向标签由连接的旋转角决定，按手机朝向设好，横拍的 DNG 才是正的。
            // 虚化保持默认，深度滤镜的方向判断依赖它
            if captureMode == .photo { setPhotoRotation() }
            pendingShots[settings.uniqueID] = shot
            pendingLock.unlock()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// 拍照连接的旋转角只影响照片里的方向标签（不旋转像素），HEIF 我们自己写方向，主要是给 DNG 用
    private func setPhotoRotation() {
        guard let connection = photoOutput.connection(with: .video) else { return }
        let angle: CGFloat = switch physicalOrientation {
        case .portrait: 90
        case .landscapeLeft: 0
        case .landscapeRight: 180
        case .portraitUpsideDown: 270
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    /// RAW / ProRAW 只在「照片」模式生效（虚化要深度数据，和 RAW 不能同时拍）。
    /// 所选 RAW 格式当前镜头不支持时退回 HEIF
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let processed: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]
        let settings: AVCapturePhotoSettings
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes
        let rawType: OSType? = switch (captureMode, photoFormat) {
        case (.photo, .raw): rawTypes.first { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        case (.photo, .proRAW): rawTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        default: nil
        }
        if let rawType {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: processed)
        } else {
            settings = AVCapturePhotoSettings(format: processed)
        }
        // ProRAW 用传感器满像素（4800 万像素机型可到 8064×6048）；其余格式 1200 万像素，避免调色/合成吃满内存
        let dims = device?.activeFormat.supportedMaxPhotoDimensions ?? []
        let target = (photoFormat == .proRAW && rawType != nil)
            ? dims.max { $0.width < $1.width }
            : dims.filter { $0.width <= 4032 }.max { $0.width < $1.width }
        if let target, target.width <= photoOutput.maxPhotoDimensions.width {
            settings.maxPhotoDimensions = target
        }
        return settings
    }

    // MARK: - 包围曝光

    /// 一次连拍 -档距 / 0 / +档距 三张（手动包围，以当前测光结果为中心），每张都存；开了合成再额外存一张 HDR
    private func captureBracket() {
        guard !isProcessing, let device else { return }
        let count = min(3, photoOutput.maxBracketedCapturePhotoCount)
        guard count >= 3, device.isExposureModeSupported(.custom) else {
            showToast("当前镜头不支持包围曝光")
            return
        }
        let bracketed = BracketEngine.bracketedSettings(device: device, spread: bracketSpread, count: count)
        let settings = AVCapturePhotoBracketSettings(
            rawPixelFormatType: 0,
            processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc],
            bracketedSettings: bracketed)
        if let dims = device.activeFormat.supportedMaxPhotoDimensions.filter({ $0.width <= 4032 }).max(by: { $0.width < $1.width }) {
            settings.maxPhotoDimensions = dims
        }
        let shot = PendingShot(mode: .bracket, format: .heif, aperture: apertureF, focusPoint: nil, toneID: toneID)
        shot.orientation = captureOrientation
        shot.bracketSpread = bracketSpread
        shot.bracketMerge = bracketMergeHDR
        setPhotoRotation()
        pendingLock.lock()
        pendingShots[settings.uniqueID] = shot
        pendingLock.unlock()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// 三张到齐后：以 0EV 那张为参考对齐另外两张（手持会有位移），曝光融合，调色后存
    private func mergeBracket(_ shot: PendingShot) {
        let frames = shot.bracketFrames.sorted { $0.sequence < $1.sequence }
        guard frames.count >= 3 else { return }
        let middle = frames.count / 2
        DispatchQueue.main.async { self.isProcessing = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let reference = frames[middle].image
            let aligner = FrameAligner(reference: reference)
            let aligned = frames.enumerated().map { index, frame in
                index == middle ? frame.image
                    : aligner.align(frame.image, exposureCompensation: Float(index - middle) * shot.bracketSpread)
            }
            let fused = BracketEngine.fuse(aligned).map { ToneEngine.apply(id: shot.toneID, to: $0) }
            let cgImage = fused.flatMap { self.ciContext.createCGImage($0, from: $0.extent) }
            let heif = cgImage.flatMap {
                PhotoSaver.heifData(from: $0, orientation: shot.orientation, metadata: frames[middle].metadata)
            }
            DispatchQueue.main.async {
                self.isProcessing = false
                guard let cgImage, let heif else {
                    self.showToast("HDR 合成失败，已保存 3 张原片")
                    return
                }
                self.lastShot = UIImage(cgImage: cgImage, scale: 1.0, orientation: UIImage.Orientation(shot.orientation))
                self.save(photo: heif)
                self.showToast("已保存 3 张包围 + 1 张 HDR 合成")
            }
        }
    }

    // MARK: - 慢门（多帧堆栈）

    /// 第一次按：2 秒防抖倒计时后开始合成；合成中再按：提前结束（倒计时阶段由 capture() 取消）
    private func startOrFinishLongExposure() {
        if longExposureProgress != nil {
            videoQueue.async { self.finishLongExposure() }
            return
        }
        guard !isProcessing else { return }
        startCountdown(2) { [weak self] in self?.beginLongExposure() }
    }

    // MARK: - 倒计时 / 连拍 / 间隔拍摄 / 星轨

    private func startCountdown(_ seconds: Int, then action: @escaping () -> Void) {
        countdownToken = UUID()
        countdownAction = action
        runCountdown(from: seconds, token: countdownToken)
    }

    /// token 防止"取消后马上重按"时，上一轮遗留的定时回调把新倒计时提前推进
    private func runCountdown(from seconds: Int, token: UUID) {
        countdown = seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.countdownToken == token, self.countdown == seconds else { return }
            if seconds > 1 {
                self.runCountdown(from: seconds - 1, token: token)
            } else {
                self.countdown = nil
                let action = self.countdownAction
                self.countdownAction = nil
                action?()
            }
        }
    }

    /// 快门按下（屏幕按住 / 实体键按下）：连拍模式下开始连拍
    func shutterPressBegan() {
        guard captureMode == .photo, effectiveDriveMode == .burst,
              countdown == nil, intervalShotsTaken == nil, burstShotsTaken == nil else { return }
        burstShotsTaken = 0
        UIApplication.shared.isIdleTimerDisabled = true
        shoot(burst: true)
    }

    /// 快门松开：在连拍就停止；返回是否处理了（没处理的话调用方按普通单击拍照）
    @discardableResult
    func shutterPressEnded() -> Bool {
        guard let taken = burstShotsTaken else { return false }
        burstShotsTaken = nil
        UIApplication.shared.isIdleTimerDisabled = false
        // 连拍时总有一张在途（上一张完成就立刻拍下一张），它照样会保存，所以 +1
        showToast("连拍 \(taken + 1) 张")
        return true
    }

    /// 连拍：上一张拍完立刻拍下一张（速度取决于机型和是否 RAW），到上限自动停
    private func continueBurst() {
        guard let taken = burstShotsTaken else { return }
        burstShotsTaken = taken + 1
        if taken + 1 >= Self.burstLimit {
            shutterPressEnded()
        } else {
            shoot(burst: true)
        }
    }

    private func startInterval() {
        guard !isProcessing else { return }
        intervalShotsTaken = 0
        starTrailOrientation = captureOrientation
        UIApplication.shared.isIdleTimerDisabled = true   // 长时间拍摄不能锁屏
        let starTrail = intervalStarTrail
        starTrailQueue.async {
            self.starTrailAccumulator = nil
            self.starTrailFrames = 0
            self.starTrailActive = starTrail
        }
        fireInterval()
        intervalTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            self?.fireInterval()
        }
    }

    private func fireInterval() {
        guard let taken = intervalShotsTaken else { return }
        if intervalCount > 0 && taken >= intervalCount {
            stopInterval()
            return
        }
        intervalShotsTaken = taken + 1
        shoot(starTrail: intervalStarTrail)
    }

    func stopInterval() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        let taken = intervalShotsTaken ?? 0
        intervalShotsTaken = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if intervalStarTrail {
            finishStarTrail()
        } else {
            showToast("间隔拍摄结束，共 \(taken) 张")
        }
    }

    /// 在 starTrailQueue 上调用
    private func accumulateStarTrail(_ image: CIImage) {
        guard starTrailActive else { return }
        if let accumulator = starTrailAccumulator, accumulator.extent == image.extent {
            // 取最亮：每颗星每张的位置都留下来，连成弧线；地景基本不变
            let lighter = image.applyingFilter("CILightenBlendMode", parameters: [
                kCIInputBackgroundImageKey: accumulator.image()
            ])
            accumulator.setImage(lighter.cropped(to: accumulator.extent))
        } else if starTrailAccumulator == nil {
            // 取最大值不需要高精度，半精度浮点够用，12MP 约 96MB
            starTrailAccumulator = CIImageAccumulator(extent: image.extent, format: .RGBAh)
            starTrailAccumulator?.setImage(image)
        } else {
            return  // 中途换了镜头/分辨率，跳过这张
        }
        starTrailFrames += 1
    }

    private func finishStarTrail() {
        let toneID = self.toneID
        let interval = intervalSeconds
        let iso = meteredISO
        let orientation = starTrailOrientation
        DispatchQueue.main.async { self.isProcessing = true }
        starTrailQueue.async { [weak self] in
            guard let self else { return }
            self.starTrailActive = false
            let frames = self.starTrailFrames
            let result = self.starTrailAccumulator?.image()
            self.starTrailAccumulator = nil
            guard frames >= 2, let result else {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showToast("星轨至少需要 2 张，已只保存单张")
                }
                return
            }
            let toned = ToneEngine.apply(id: toneID, to: result)
            let cgImage = self.ciContext.createCGImage(toned, from: toned.extent)
            let metadata = PhotoSaver.syntheticMetadata(exposureSeconds: Double(frames) * interval, iso: iso,
                                                        comment: "ManualCam 星轨 \(frames) 张叠加")
            let heif = cgImage.flatMap { PhotoSaver.heifData(from: $0, orientation: orientation, metadata: metadata) }
            DispatchQueue.main.async {
                self.isProcessing = false
                guard let cgImage, let heif else { return }
                self.lastShot = UIImage(cgImage: cgImage, scale: 1.0, orientation: UIImage.Orientation(orientation))
                self.save(photo: heif)
                self.showToast("星轨合成完成：\(frames) 张叠加")
            }
        }
    }

    private func beginLongExposure() {
        let duration = longExposureSeconds
        let blend = longExposureBlend
        let handheld = longExposureHandheld
        longExposureOrientation = captureOrientation
        longExposureProgress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        // P 档下锁住自动曝光：车灯扫过时测光会跳，合成出来亮度会不均匀
        sessionQueue.async { [weak self] in
            guard let device = self?.device, device.exposureMode == .continuousAutoExposure,
                  (try? device.lockForConfiguration()) != nil else { return }
            device.exposureMode = .locked
            device.unlockForConfiguration()
        }
        videoQueue.async { [weak self] in
            self?.stacker = LongExposureStacker(duration: duration, blend: blend, aligns: handheld)
        }
    }

    /// 在 videoQueue 上调用
    private func finishLongExposure() {
        guard let stacker else { return }
        self.stacker = nil
        let toneID = self.toneID
        DispatchQueue.main.async {
            self.longExposureProgress = nil
            self.isProcessing = true
            UIApplication.shared.isIdleTimerDisabled = false
        }
        applyExposure() // 恢复测光

        guard let result = stacker.image else {
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }
        let toned = ToneEngine.apply(id: toneID, to: result)
        let cgImage = ciContext.createCGImage(toned, from: toned.extent)
        let frames = stacker.frameCount
        let elapsed = stacker.progress * stacker.duration
        let seconds = Int(elapsed.rounded())
        let comment = "ManualCam 慢门 \(stacker.blend.name) \(frames) 帧合成"
        let metadata = PhotoSaver.syntheticMetadata(exposureSeconds: elapsed, iso: meteredISO, comment: comment)
        DispatchQueue.main.async {
            self.isProcessing = false
            guard let cgImage else { return }
            let orientation = self.longExposureOrientation
            self.lastShot = UIImage(cgImage: cgImage, scale: 1.0, orientation: UIImage.Orientation(orientation))
            if let data = PhotoSaver.heifData(from: cgImage, orientation: orientation, metadata: metadata) {
                self.save(photo: data)
            }
            self.showToast("慢门 \(seconds)s · \(stacker.blend.name) · \(frames) 帧合成")
        }
    }

    private func cancelLongExposure() {
        countdown = nil
        longExposureProgress = nil
        UIApplication.shared.isIdleTimerDisabled = false
        videoQueue.async { [weak self] in
            guard let self, self.stacker != nil else { return }
            self.stacker = nil
            self.applyExposure()
        }
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }

    private func save(photo: Data, raw: Data? = nil) {
        PhotoSaver.save(photo: photo, raw: raw) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.errorMessage = error }
        }
    }

    // MARK: - 峰值对焦与直方图

    /// 峰值对焦：边缘检测 → 染红 → 叠加回原图。合焦处纹理锐利，红色最密集。
    private func applyFocusPeaking(to image: CIImage) -> CIImage {
        let edges = image.applyingFilter("CIEdges", parameters: [
            kCIInputIntensityKey: 3.0
        ])
        // 把白色边缘染成红色（绿蓝通道清零）
        let redEdges = edges.applyingFilter("CIColorMatrix", parameters: [
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        return redEdges.applyingFilter("CIAdditionCompositing", parameters: [
            kCIInputBackgroundImageKey: image
        ])
    }

    /// 斑马纹：亮度超过阈值的区域（过曝）叠加 45° 黑白条纹提示，阈值对应 8-bit ~242/255
    private func applyZebra(to image: CIImage) -> CIImage {
        guard let thresholdFilter = CIFilter(name: "CIColorThreshold") else { return image }
        thresholdFilter.setValue(image, forKey: kCIInputImageKey)
        thresholdFilter.setValue(0.95, forKey: "inputThreshold")
        guard let mask = thresholdFilter.outputImage else { return image }

        guard let stripesFilter = CIFilter(name: "CIStripesGenerator") else { return image }
        stripesFilter.setValue(CIColor.black, forKey: "inputColor0")
        stripesFilter.setValue(CIColor.white, forKey: "inputColor1")
        stripesFilter.setValue(10.0, forKey: "inputWidth")
        guard let stripes = stripesFilter.outputImage?
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4)) else { return image }

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(stripes, forKey: kCIInputImageKey)
        blend.setValue(image, forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: "inputMaskImage")
        return (blend.outputImage ?? image).cropped(to: image.extent)
    }

    /// 降采样到 64x64 后统计 RGB 直方图（每 10 帧算一次，避免占用预览性能）
    private func computeHistogram(from image: CIImage) {
        let side = 64
        let scale = min(CGFloat(side) / image.extent.width, CGFloat(side) / image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var bitmap = [UInt8](repeating: 0, count: side * side * 4)
        ciContext.render(small,
                         toBitmap: &bitmap,
                         rowBytes: side * 4,
                         bounds: CGRect(x: 0, y: 0, width: side, height: side),
                         format: .RGBA8,
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        var data = HistogramData()
        for i in stride(from: 0, to: bitmap.count, by: 4) {
            data.r[Int(bitmap[i]) / 8] += 1
            data.g[Int(bitmap[i + 1]) / 8] += 1
            data.b[Int(bitmap[i + 2]) / 8] += 1
        }
        let peak = max(data.r.max() ?? 1, data.g.max() ?? 1, data.b.max() ?? 1, 1)
        for i in 0..<32 {
            data.r[i] /= peak; data.g[i] /= peak; data.b[i] /= peak
        }
        DispatchQueue.main.async { self.histogram = data }
    }
}

// MARK: - 实时预览帧处理（LUT 色调管线 + 峰值对焦 + 直方图）

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        lastRawFrame = ciImage
        frameCounter += 1

        if frameCounter % 6 == 0 {
            sessionQueue.async { [weak self] in self?.meteringStep() }
        }

        // 慢门合成中：取景器显示正在累积的画面（能实时看到光轨/流水慢慢成形）
        if let stacker {
            let progress = stacker.add(ciImage, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            DispatchQueue.main.async {
                if self.longExposureProgress != nil { self.longExposureProgress = progress }
            }
            if stacker.isFinished {
                finishLongExposure()
                return
            }
            // 每 3 帧刷一次预览，合成本身已经很吃 GPU
            guard frameCounter % 3 == 0, let accumulated = stacker.image else { return }
            let toned = ToneEngine.apply(id: toneID, to: accumulated)
            guard let cgImage = ciContext.createCGImage(toned, from: toned.extent) else { return }
            DispatchQueue.main.async { self.previewImage = cgImage }
            return
        }

        var source = ciImage
        if captureMode == .bokeh {
            updatePreviewSubjectMask(from: ciImage)
            if let mask = previewSubjectMask {
                source = BokehEngine.previewBlur(ciImage, mask: mask, aperture: apertureF)
            }
        } else if previewSubjectMask != nil {
            previewSubjectMask = nil
        }

        let toned = ToneEngine.apply(id: toneID, to: source)
        var display = zebraEnabled ? applyZebra(to: toned) : toned
        if focusPeakingEnabled { display = applyFocusPeaking(to: display) }

        guard let cgImage = ciContext.createCGImage(display, from: display.extent) else { return }

        if histogramEnabled && frameCounter % 10 == 0 {
            computeHistogram(from: toned)
        }

        DispatchQueue.main.async {
            self.previewImage = cgImage
        }
    }
}

// MARK: - 虚化实时预览

extension CameraManager {
    /// 在 videoQueue 上调用：上一次识别完成后，隔几帧再识别一次（约每秒 3~4 次）
    private func updatePreviewSubjectMask(from frame: CIImage) {
        guard !maskInFlight, frameCounter % 8 == 0 else { return }
        maskInFlight = true
        // 预览帧是传感器方向，按手机当前朝向转正后再识别
        let orientation = captureOrientation
        maskQueue.async { [weak self] in
            let mask = BokehEngine.subjectMask(for: frame, uprightOrientation: orientation,
                                               maxSide: 640, feather: frame.extent.width * 0.006)
            self?.videoQueue.async {
                self?.previewSubjectMask = mask
                self?.maskInFlight = false
            }
        }
    }
}

// MARK: - 拍照回调

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        pendingLock.lock()
        let shot = pendingShots[photo.resolvedSettings.uniqueID]
        pendingLock.unlock()
        guard let shot else { return }

        if let error {
            DispatchQueue.main.async { self.errorMessage = "拍照失败：\(error.localizedDescription)" }
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }

        // RAW 原片原样保存（DNG），不做任何调色——这正是要 RAW 的意义
        if photo.isRawPhoto {
            shot.rawData = data
            return
        }
        guard let ciImage = CIImage(data: data) else { return }

        if shot.mode == .bracket {
            // 每张都调色存一份（摄影师通常要原片自己挑），未调色原图留给 HDR 合成
            let toned = ToneEngine.apply(id: shot.toneID, to: ciImage)
            if let cgImage = ciContext.createCGImage(toned, from: toned.extent),
               let heif = PhotoSaver.heifData(from: cgImage, orientation: shot.orientation, metadata: photo.metadata) {
                save(photo: heif)
                let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: UIImage.Orientation(shot.orientation))
                DispatchQueue.main.async { self.lastShot = image }
            }
            pendingLock.lock()
            shot.bracketFrames.append((photo.sequenceCount, ciImage, photo.metadata))
            pendingLock.unlock()
            return
        }

        guard shot.mode == .bokeh else {
            if shot.starTrail {
                starTrailQueue.async { self.accumulateStarTrail(ciImage) }
            }
            let toned = ToneEngine.apply(id: shot.toneID, to: ciImage)
            guard let cgImage = ciContext.createCGImage(toned, from: toned.extent) else { return }

            // 按拍摄时手机朝向写入方向（竖拍 / 横拍都正）；EXIF（ISO/快门/镜头/GPS）从原片带过来
            shot.photoData = PhotoSaver.heifData(from: cgImage, orientation: shot.orientation, metadata: photo.metadata)
            let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: UIImage.Orientation(shot.orientation))
            DispatchQueue.main.async {
                self.lastShot = image
            }
            return  // 等 didFinishCaptureFor 时 RAW 和 HEIF 都到齐再一起存
        }

        // 虚化：合成比较慢（Vision 抠图 + 大半径模糊），放到后台，不卡下一张预览
        let metadata = photo.metadata
        DispatchQueue.main.async { self.isProcessing = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (blurred, method) = BokehEngine.render(data: data, raw: ciImage, aperture: shot.aperture,
                                                       focusPoint: shot.focusPoint, orientation: shot.orientation,
                                                       context: self.ciContext)
            let toned = ToneEngine.apply(id: shot.toneID, to: blurred)
            let cgImage = self.ciContext.createCGImage(toned, from: toned.extent)
            // BokehEngine 输出已经转正
            let heif = cgImage.flatMap { PhotoSaver.heifData(from: $0, orientation: .up, metadata: metadata) }
            DispatchQueue.main.async {
                self.isProcessing = false
                guard let cgImage else { return }
                self.lastShot = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
                if let heif { self.save(photo: heif) }
                self.showToast(method == .none
                               ? "未识别到主体，已保存原图"
                               : "\(method.name) \(ExposureStops.apertureLabel(shot.aperture))")
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        pendingLock.lock()
        let shot = pendingShots.removeValue(forKey: resolvedSettings.uniqueID)
        pendingLock.unlock()
        guard let shot else { return }
        if shot.isBurst {
            DispatchQueue.main.async { self.continueBurst() }
        }
        if shot.mode == .bracket {
            if shot.bracketMerge { mergeBracket(shot) } else {
                DispatchQueue.main.async { self.showToast("已保存 \(shot.bracketFrames.count) 张包围曝光") }
            }
            return
        }
        // 虚化在自己的后台任务里保存
        guard shot.mode != .bokeh else { return }

        if let photo = shot.photoData {
            save(photo: photo, raw: shot.rawData)
            if shot.rawData != nil {
                DispatchQueue.main.async { self.showToast("已保存 \(shot.format.name) + HEIF") }
            }
        } else if let raw = shot.rawData {
            // 极少数情况只拿到 DNG：单独存为照片资源
            save(photo: raw)
        }
    }
}
