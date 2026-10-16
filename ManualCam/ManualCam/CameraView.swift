import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct CameraView: View {
    @ObservedObject var camera: CameraManager
    @StateObject private var lutStore = CustomLUTStore.shared
    @StateObject private var level = LevelManager()
    @StateObject private var presets = PresetStore()
    @State private var showViewer = false
    @State private var showLUTImporter = false
    @State private var importError: String?
    @State private var gridEnabled = false
    @State private var levelEnabled = false
    /// 捏合手势开始时的基准变焦值，用于把手势的相对缩放叠加到当前 zoomFactor 上
    @State private var pinchBaseZoom: CGFloat = 1.0
    /// 点击对焦框：当前显示位置（屏幕坐标）+ 控制淡出的透明度
    @State private var focusReticlePoint: CGPoint?
    @State private var focusReticleOpacity: Double = 0
    @State private var focusReticleTask: Task<Void, Never>?
    /// 底部参数滑杆面板是否展开（收起后只留快门+缩略图，让取景框不被挡住）
    @State private var showControls = true
    /// 对焦放大镜：拖手动对焦滑杆时显示，松手后稍等再收起
    @State private var loupeVisible = false
    @State private var loupeHideTask: Task<Void, Never>?
    /// 放大镜取景中心（设备坐标 0~1），默认画面中心，点击对焦后跟随对焦点
    @State private var loupeCenter = CGPoint(x: 0.5, y: 0.5)
    /// 点选白平衡模式：下一次点击画面用于白平衡取样，而不是对焦
    @State private var pickingWhiteBalance = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 实时预览（已带色调 / 峰值对焦）
            if let cg = camera.previewImage {
                GeometryReader { geo in
                    Image(decorative: cg, scale: 1.0, orientation: .right)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let target = pinchBaseZoom * value
                                    camera.zoomFactor = min(max(target, camera.zoomRange.lowerBound), camera.zoomRange.upperBound)
                                }
                                .onEnded { _ in
                                    pinchBaseZoom = camera.zoomFactor
                                }
                        )
                        .onTapGesture { location in
                            handleTap(at: location, containerSize: geo.size, cgImage: cg)
                        }

                    if gridEnabled {
                        GridOverlay()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .allowsHitTesting(false)
                    }

                    if levelEnabled {
                        LevelOverlay(rollDegrees: level.rollDegrees)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .allowsHitTesting(false)
                    }

                    if loupeVisible, let crop = loupeImage(from: cg) {
                        FocusLoupe(image: crop)
                            .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .ignoresSafeArea()

                if let point = focusReticlePoint {
                    FocusReticle()
                        .position(point)
                        .opacity(focusReticleOpacity)
                        .allowsHitTesting(false)
                }
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                // 顶部：色调选择 + 辅助开关
                HStack(spacing: 10) {
                    toneMenu

                    // 拍摄格式：只在照片模式、且机型支持 RAW 时出现
                    if camera.captureMode == .photo && camera.supportedFormats.count > 1 {
                        formatMenu
                    }

                    if camera.availableDriveModes.count > 1 {
                        driveMenu
                    }

                    Spacer()

                    // 峰值对焦开关
                    Toggle(isOn: $camera.focusPeakingEnabled) {
                        Image(systemName: "scope")
                            .rotatesWithDevice(camera.physicalOrientation)
                    }
                    .toggleStyle(.button)
                    .tint(.red)

                    // 直方图开关
                    Toggle(isOn: $camera.histogramEnabled) {
                        Image(systemName: "chart.bar.fill")
                            .rotatesWithDevice(camera.physicalOrientation)
                    }
                    .toggleStyle(.button)
                    .tint(.yellow)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // 第二行：辅助工具（斑马纹/网格线/水平仪）+ 镜头选择/变焦倍数，避免和上面挤在一起被推出屏幕
                HStack(spacing: 8) {
                    // 当前曝光档位：P / S / ISO / M（由 ISO、快门两个自动开关组合决定）
                    Text(camera.exposureProgram.badge)
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .rotatesWithDevice(camera.physicalOrientation)

                    presetMenu

                    // 斑马纹开关（过曝提示）
                    Toggle(isOn: $camera.zebraEnabled) {
                        Image(systemName: "sun.max.trianglebadge.exclamationmark")
                            .rotatesWithDevice(camera.physicalOrientation)
                    }
                    .toggleStyle(.button)
                    .tint(.orange)

                    // 网格线开关
                    Toggle(isOn: $gridEnabled) {
                        Image(systemName: "grid")
                            .rotatesWithDevice(camera.physicalOrientation)
                    }
                    .toggleStyle(.button)
                    .tint(.white)

                    // 水平仪开关
                    Toggle(isOn: $levelEnabled) {
                        Image(systemName: "gyroscope")
                            .rotatesWithDevice(camera.physicalOrientation)
                    }
                    .toggleStyle(.button)
                    .tint(.green)

                    // 虚化模式由双摄镜头组接管，不允许手动切物理镜头
                    if camera.availableLensTypes.count > 1 && camera.captureMode != .bokeh {
                        lensPicker
                        if camera.zoomFactor > camera.zoomRange.lowerBound + 0.05 {
                            Text(String(format: "%.1fx", camera.zoomFactor))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.yellow)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.5))
                                .clipShape(Capsule())
                        }
                    }

                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.top, 6)

                // 直方图悬浮窗
                if camera.histogramEnabled {
                    HStack {
                        Spacer()
                        HistogramView(data: camera.histogram)
                            .frame(width: 120, height: 64)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.trailing, 12)
                    }
                }

                Spacer()

                // 慢门倒计时（大数字居中）
                if let countdown = camera.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 96, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .rotatesWithDevice(camera.physicalOrientation)
                    Spacer()
                }

                // 拍后提示 / 当前模式提示
                if let toast = camera.toast ?? modeHint {
                    Text(toast)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.bottom, 6)
                        .animation(.easeInOut, value: toast)
                }

                // 底部控制区
                VStack(spacing: 10) {
                    // 展开/收起手柄：挡住取景框时点一下收起，只留快门
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { showControls.toggle() }
                    } label: {
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 36, height: 5)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }

                    // 相机控制键拨盘展开时系统会画自己的刻度，收起 App 面板避免叠在一起
                    if showControls && !camera.controlsOverlayActive {
                        VStack(spacing: 10) {
                            controlRow(title: "对焦",
                                       value: focusText,
                                       isAuto: $camera.autoFocus,
                                       sliderValue: $camera.lensPosition,
                                       range: 0...1,
                                       onEditingChanged: setLoupe)

                            stopRow(title: "ISO",
                                    value: isoText,
                                    isAuto: $camera.autoISO,
                                    stops: ExposureStops.stops(ExposureStops.iso, in: camera.isoRange),
                                    current: camera.autoISO ? camera.meteredISO : camera.iso,
                                    onChange: { camera.iso = $0 })

                            stopRow(title: "快门",
                                    value: shutterText,
                                    isAuto: $camera.autoShutter,
                                    stops: ExposureStops.stops(ExposureStops.shutter, in: camera.shutterRange),
                                    current: camera.autoShutter ? camera.meteredShutter : camera.shutterSeconds,
                                    onChange: { camera.shutterSeconds = $0 })

                            evRow()

                            switch camera.captureMode {
                            case .longExposure: longExposureRows()
                            case .bokeh: apertureRow()
                            case .bracket: bracketRows()
                            case .photo:
                                if camera.effectiveDriveMode == .interval { intervalRows() }
                            }

                            whiteBalanceRows()
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    modePicker

                    HStack {
                        // 左下：最近一张，点开进入高倍放大查看器
                        Button {
                            showViewer = true   // 打开 App 内相册（本 App 拍的所有照片）
                        } label: {
                            if let shot = camera.lastShot {
                                Image(uiImage: shot)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .rotatesWithDevice(camera.physicalOrientation)
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                    .frame(width: 48, height: 48)
                            }
                        }

                        Spacer()

                        // 快门按钮：连拍模式按住连拍、松手停；其他模式单击
                        if camera.captureMode == .photo && camera.effectiveDriveMode == .burst {
                            shutterButtonLabel
                                .contentShape(Circle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            if camera.burstShotsTaken == nil {
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                camera.shutterPressBegan()
                                            }
                                        }
                                        .onEnded { _ in camera.shutterPressEnded() }
                                )
                        } else {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                camera.capture()
                            } label: {
                                shutterButtonLabel
                            }
                            .disabled(camera.isProcessing)
                        }

                        Spacer()
                        Color.clear.frame(width: 48, height: 48) // 对称占位
                    }
                    .padding(.bottom, 8)
                }
                .padding(.horizontal)
                .background(.black.opacity(0.55))
            }
        }
        .fullScreenCover(isPresented: $showViewer) {
            GalleryView(fallback: camera.lastShot) { showViewer = false }
        }
        .fileImporter(isPresented: $showLUTImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]) { result in
            switch result {
            case .success(let url):
                do {
                    let item = try lutStore.importLUT(from: url)
                    camera.toneID = item.id
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("LUT 导入失败", isPresented: .constant(importError != nil)) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onChange(of: levelEnabled) { _, enabled in
            if enabled { level.start() } else { level.stop() }
        }
        .onDisappear { level.stop() }
        // 音量键 / 相机控制键按压 = 快门
        .background(
            HardwareShutterButton(
                onPress: { camera.shutterPressBegan() },
                onRelease: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if !camera.shutterPressEnded() { camera.capture() }
                })
            .frame(width: 1, height: 1)
        )
        // 相机界面固定深色：系统浅色模式下滑杆未填充轨道、分段控件文字在黑底上几乎看不见
        .preferredColorScheme(.dark)
        // 切镜头 / 进出虚化时变焦范围会变，捏合基准同步到新的起点，避免下一次捏合跳变
        .onChange(of: camera.zoomRange) { _, range in
            pinchBaseZoom = range.lowerBound
        }
    }

    // MARK: - 点击对焦 / 点测光

    /// 把屏幕上的点击位置换算成设备坐标系（0,0~1,1，横向 home 键在右的坐标系），
    /// 再交给 CameraManager 触发对焦+测光；同时在点击处显示一个短暂淡出的取景框。
    ///
    /// 预览图是 .scaledToFit，实际显示区域可能因为宽高比不同而带上下或左右的黑边（letterbox），
    /// 所以必须先算出图像在容器里的真实矩形，点在黑边里就直接忽略。
    private func handleTap(at location: CGPoint, containerSize: CGSize, cgImage: CGImage) {
        // 预览帧是横向传感器画面，加 .right 方向后旋转 90° 显示成竖屏，所以显示宽高是传感器的高/宽互换
        let displayedAspect = CGFloat(cgImage.height) / CGFloat(cgImage.width)
        let containerAspect = containerSize.width / containerSize.height

        let imageRect: CGRect
        if displayedAspect > containerAspect {
            let h = containerSize.width / displayedAspect
            imageRect = CGRect(x: 0, y: (containerSize.height - h) / 2, width: containerSize.width, height: h)
        } else {
            let w = containerSize.height * displayedAspect
            imageRect = CGRect(x: (containerSize.width - w) / 2, y: 0, width: w, height: containerSize.height)
        }

        guard imageRect.contains(location) else { return }

        let xDisplay = (location.x - imageRect.minX) / imageRect.width
        let yDisplay = (location.y - imageRect.minY) / imageRect.height

        // 显示坐标 -> 传感器（设备）坐标：见 CameraManager.focusAndExpose 的坐标系说明，
        // 是显示时旋转 90° 的逆变换
        let devicePoint = CGPoint(x: 1 - yDisplay, y: xDisplay)
        if pickingWhiteBalance {
            pickingWhiteBalance = false
            camera.whiteBalance(at: devicePoint)
            showFocusReticle(at: location)
            return
        }
        camera.focusAndExpose(at: devicePoint)
        loupeCenter = devicePoint
        showFocusReticle(at: location)
    }

    private func showFocusReticle(at point: CGPoint) {
        focusReticleTask?.cancel()
        focusReticlePoint = point
        focusReticleOpacity = 1
        focusReticleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { focusReticleOpacity = 0 }
        }
    }

    // MARK: - 对焦放大镜

    private func setLoupe(_ editing: Bool) {
        loupeHideTask?.cancel()
        if editing {
            withAnimation(.easeOut(duration: 0.15)) { loupeVisible = true }
        } else {
            loupeHideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.25)) { loupeVisible = false }
            }
        }
    }

    /// 从预览帧（传感器方向）里裁出对焦点附近的一小块。裁切边长取短边的 1/10，
    /// 放大镜显示 180pt，相对取景器约 4~5 倍放大；峰值对焦开着时红边也一起放大
    private func loupeImage(from cg: CGImage) -> CGImage? {
        let side = CGFloat(min(cg.width, cg.height)) / 10
        let cx = loupeCenter.x * CGFloat(cg.width)
        let cy = loupeCenter.y * CGFloat(cg.height)
        let x = min(max(cx - side / 2, 0), CGFloat(cg.width) - side)
        let y = min(max(cy - side / 2, 0), CGFloat(cg.height) - side)
        return cg.cropping(to: CGRect(x: x, y: y, width: side, height: side).integral)
    }

    // MARK: - 镜头选择（超广角 / 广角 / 长焦）

    private var lensPicker: some View {
        HStack(spacing: 4) {
            ForEach(camera.availableLensTypes, id: \.self) { type in
                Button {
                    camera.switchLens(to: type)
                } label: {
                    Text(lensLabel(for: type))
                        .font(.caption2.bold())
                        .frame(width: 40, height: 24)
                        .background(camera.currentLensType == type ? Color.yellow : Color.black.opacity(0.5))
                        .foregroundStyle(camera.currentLensType == type ? .black : .white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(4)
        .background(.black.opacity(0.3))
        .clipShape(Capsule())
    }

    private func lensLabel(for type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInUltraWideCamera: return "超广"
        case .builtInWideAngleCamera: return "广角"
        case .builtInTelephotoCamera: return "长焦"
        default: return "镜头"
        }
    }

    // MARK: - 自定义档 C1 / C2 / C3

    private var presetMenu: some View {
        Menu {
            Section("调用") {
                ForEach(PresetStore.slotNames, id: \.self) { slot in
                    Button {
                        if let preset = presets.presets[slot] {
                            camera.apply(preset)
                            camera.showToast("已调用 \(slot)：\(preset.summary)")
                        }
                    } label: {
                        Text(slot)
                        Text(presets.presets[slot]?.summary ?? "空")
                    }
                    .disabled(presets.presets[slot] == nil)
                }
            }
            Menu("把当前参数存为…") {
                ForEach(PresetStore.slotNames, id: \.self) { slot in
                    Button(slot) {
                        let preset = camera.makePreset()
                        presets.save(preset, to: slot)
                        camera.showToast("已存为 \(slot)：\(preset.summary)")
                    }
                }
            }
        } label: {
            Text("C")
                .font(.caption.bold().monospaced())
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.7), lineWidth: 1))
                .rotatesWithDevice(camera.physicalOrientation)
        }
        .disabled(camera.longExposureProgress != nil || camera.countdown != nil)
    }

    // MARK: - 驱动模式菜单（单拍 / 连拍 / 自拍 / 间隔）

    private var driveMenu: some View {
        Menu {
            Picker("驱动", selection: $camera.driveMode) {
                ForEach(camera.availableDriveModes) { mode in
                    Label(mode.name, systemImage: mode.symbol).tag(mode)
                }
            }
        } label: {
            Image(systemName: camera.effectiveDriveMode.symbol)
                .font(.subheadline)
                .frame(width: 34, height: 34)
                .background(camera.effectiveDriveMode == .single ? Color.black.opacity(0.6) : Color.yellow)
                .foregroundStyle(camera.effectiveDriveMode == .single ? .white : .black)
                .clipShape(Circle())
                .rotatesWithDevice(camera.physicalOrientation)
        }
        .disabled(camera.intervalShotsTaken != nil || camera.burstShotsTaken != nil || camera.countdown != nil)
    }

    /// 间隔拍摄参数（照片模式 + 间隔驱动时出现在参数面板里）
    @ViewBuilder
    private func intervalRows() -> some View {
        HStack(spacing: 8) {
            Text("间隔")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Picker("间隔", selection: $camera.intervalSeconds) {
                ForEach([2.0, 5, 10, 30, 60], id: \.self) { s in
                    Text("\(Int(s))s").tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
        .foregroundStyle(.white)

        HStack(spacing: 8) {
            Text("张数")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Picker("张数", selection: $camera.intervalCount) {
                ForEach([10, 30, 100, 300, 0], id: \.self) { n in
                    Text(n == 0 ? "不限" : "\(n)").tag(n)
                }
            }
            .pickerStyle(.segmented)
        }
        .foregroundStyle(.white)

        HStack(spacing: 8) {
            Text("星轨")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Toggle("逐张取最亮，额外合成一张星轨", isOn: $camera.intervalStarTrail)
                .font(.caption)
                .tint(.yellow)
        }
        .foregroundStyle(.white)
    }

    // MARK: - 拍摄格式菜单（HEIF / RAW / ProRAW）

    private var formatMenu: some View {
        Menu {
            Picker("格式", selection: $camera.photoFormat) {
                ForEach(camera.supportedFormats) { format in
                    Text(format.name).tag(format)
                }
            }
        } label: {
            Text(camera.photoFormat.name)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(camera.photoFormat == .heif ? Color.black.opacity(0.6) : Color.yellow)
                .foregroundStyle(camera.photoFormat == .heif ? .white : .black)
                .clipShape(Capsule())
        }
    }

    // MARK: - 色调选择菜单（内置预设 + 导入的 LUT）

    private var toneMenu: some View {
        Menu {
            ForEach(ToneEngine.builtIns) { item in
                Button {
                    camera.toneID = item.id
                } label: {
                    if camera.toneID == item.id {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }

            if !lutStore.items.isEmpty {
                Divider()
                ForEach(lutStore.items) { item in
                    Button {
                        camera.toneID = item.id
                    } label: {
                        if camera.toneID == item.id {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            }

            Divider()
            Button {
                showLUTImporter = true
            } label: {
                Label("导入 .cube LUT…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "camera.filters")
                Text(currentToneName)
                    .font(.subheadline).bold()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6))
            .clipShape(Capsule())
            .foregroundStyle(.white)
        }
    }

    private var currentToneName: String {
        ToneEngine.builtIns.first { $0.id == camera.toneID }?.name
            ?? lutStore.items.first { $0.id == camera.toneID }?.name
            ?? "标准"
    }

    // MARK: - 参数控制行

    private var focusText: String {
        camera.autoFocus ? "自动" : String(format: "%.2f", camera.lensPosition)
    }

    private func controlRow(title: String, value: String,
                            isAuto: Binding<Bool>,
                            sliderValue: Binding<Float>,
                            range: ClosedRange<Float>,
                            onEditingChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(.yellow)
            Toggle("自动", isOn: isAuto)
                .labelsHidden()
                .tint(.yellow)
            Slider(value: sliderValue, in: range, onEditingChanged: onEditingChanged)
                .disabled(isAuto.wrappedValue)
                .tint(.yellow)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    /// 按标准挡位跳的滑杆（快门 / ISO / 光圈），手感接近相机拨盘：每跳一档轻震一下。
    /// 自动状态下滑块跟随相机实际测光值移动，但不可拖
    private func stopRow(title: String, value: String,
                         isAuto: Binding<Bool>?,
                         trailingLabel: String? = nil,
                         stops: [Float], current: Float,
                         onChange: @escaping (Float) -> Void) -> some View {
        let disabled = isAuto?.wrappedValue ?? false
        let index = Binding<Double>(
            get: { Double(ExposureStops.nearestIndex(of: current, in: stops)) },
            set: { newValue in
                let i = min(max(Int(newValue.rounded()), 0), stops.count - 1)
                guard i != ExposureStops.nearestIndex(of: current, in: stops) else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                onChange(stops[i])
            }
        )
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(.yellow)
            if let isAuto {
                Toggle("自动", isOn: isAuto)
                    .labelsHidden()
                    .tint(.yellow)
            } else {
                Text(trailingLabel ?? "")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 51)
            }
            Slider(value: index, in: 0...Double(max(stops.count - 1, 1)), step: 1)
                .disabled(disabled || stops.count < 2)
                .tint(.yellow)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    private var isoText: String {
        let v = camera.autoISO ? camera.meteredISO : camera.iso
        return (camera.autoISO ? "A " : "ISO ") + "\(Int(v.rounded()))"
    }

    private var shutterText: String {
        let s = camera.autoShutter ? camera.meteredShutter : camera.shutterSeconds
        guard s > 0 else { return "A" }
        return (camera.autoShutter ? "A " : "") + ExposureStops.shutterLabel(s)
    }

    /// 曝光补偿：P / S / ISO 优先档下偏移测光目标；M 档下滑杆置灰，改为显示测光表读数（当前参数离正确曝光差几档）
    private func evRow() -> some View {
        let isManual = camera.exposureProgram == .manual
        return HStack(spacing: 8) {
            Text(isManual ? "测光" : "EV")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Text(evText)
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(isManual && abs(camera.meterOffset) > 1 ? .orange : .yellow)
            Color.clear.frame(width: 51, height: 1) // 只给宽度会在竖直方向无限拉伸、把各行撑散；对齐其他行"自动"开关的宽度，让所有滑杆左对齐
            Slider(value: $camera.exposureBias, in: camera.exposureBiasRange, step: 1.0 / 3.0)
                .disabled(isManual)
                .tint(.yellow)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(isManual ? .white.opacity(0.6) : .white)
    }

    private var evText: String {
        let v = camera.exposureProgram == .manual ? camera.meterOffset : camera.exposureBias
        return (v >= 0 ? "+" : "") + String(format: "%.1f", v)
    }

    // MARK: - 慢门 / 虚化 参数

    @ViewBuilder
    private func longExposureRows() -> some View {
        HStack(spacing: 8) {
            Text("时长")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Picker("时长", selection: $camera.longExposureSeconds) {
                ForEach(ExposureStops.longExposure, id: \.self) { s in
                    Text("\(Int(s))s").tag(s)
                }
            }
            .pickerStyle(.segmented)
        }
        .foregroundStyle(.white)
        .disabled(camera.longExposureProgress != nil)

        HStack(spacing: 8) {
            Text("效果")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Picker("效果", selection: $camera.longExposureBlend) {
                ForEach(LongExposureBlend.allCases) { b in
                    Text(b.name).tag(b)
                }
            }
            .pickerStyle(.segmented)
        }
        .foregroundStyle(.white)
        .disabled(camera.longExposureProgress != nil)

        HStack(spacing: 8) {
            Text("手持")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Toggle(camera.longExposureBlend.requiresAlignment ? "逐帧对齐（夜景必开）" : "逐帧对齐，背景不糊",
                   isOn: camera.longExposureBlend.requiresAlignment ? .constant(true) : $camera.longExposureHandheld)
                .font(.caption)
                .tint(.yellow)
                .disabled(camera.longExposureBlend.requiresAlignment)
        }
        .foregroundStyle(.white)
        .disabled(camera.longExposureProgress != nil)
    }

    /// 白平衡：色温滑杆 + 吸管（点选白平衡）；手动时多一行色调（绿 ↔ 品红）
    @ViewBuilder
    private func whiteBalanceRows() -> some View {
        HStack(spacing: 8) {
            controlRow(title: "白平衡",
                       value: "\(Int(camera.temperature))K",
                       isAuto: $camera.autoWhiteBalance,
                       sliderValue: $camera.temperature,
                       range: 2500...9000)
            Button {
                pickingWhiteBalance.toggle()
            } label: {
                Image(systemName: "eyedropper")
                    .font(.footnote)
                    .foregroundStyle(pickingWhiteBalance ? .black : .yellow)
                    .frame(width: 28, height: 28)
                    .background(pickingWhiteBalance ? Color.yellow : Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
        }
        if !camera.autoWhiteBalance {
            HStack(spacing: 8) {
                Text("色调")
                    .font(.caption).bold()
                    .frame(width: 44, alignment: .leading)
                Text((camera.tint >= 0 ? "+" : "") + "\(Int(camera.tint))")
                    .font(.caption.monospacedDigit())
                    .frame(width: 72, alignment: .leading)
                    .foregroundStyle(.yellow)
                Text("绿").font(.caption2).foregroundStyle(.green).frame(width: 51, alignment: .trailing)
                Slider(value: $camera.tint, in: -150...150, step: 1)
                    .tint(.yellow)
                    .frame(maxWidth: .infinity)
                Text("品红").font(.caption2).foregroundStyle(.pink)
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func bracketRows() -> some View {
        HStack(spacing: 8) {
            Text("档距")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Picker("档距", selection: $camera.bracketSpread) {
                ForEach(BracketEngine.spreads, id: \.self) { ev in
                    Text("±" + String(format: "%g", ev)).tag(ev)
                }
            }
            .pickerStyle(.segmented)
        }
        .foregroundStyle(.white)

        HStack(spacing: 8) {
            Text("HDR")
                .font(.caption).bold()
                .frame(width: 44, alignment: .leading)
            Toggle("合成 HDR", isOn: $camera.bracketMergeHDR)
                .font(.caption)
                .tint(.yellow)
        }
        .foregroundStyle(.white)
    }

    private func apertureRow() -> some View {
        stopRow(title: "光圈",
                value: ExposureStops.apertureLabel(camera.apertureF),
                isAuto: nil,
                trailingLabel: camera.depthAvailable ? "深度" : "AI 主体",
                stops: ExposureStops.aperture,
                current: camera.apertureF,
                onChange: { camera.apertureF = $0 })
    }

    /// 取景区底部的模式提示（拍后提示优先显示）
    private var modeHint: String? {
        if pickingWhiteBalance { return "点击画面中白色或灰色的区域校准白平衡" }
        if let taken = camera.intervalShotsTaken {
            let total = camera.intervalCount > 0 ? "/\(camera.intervalCount)" : ""
            return "间隔拍摄中 \(taken)\(total) · 每 \(Int(camera.intervalSeconds)) 秒" + (camera.intervalStarTrail ? " · 星轨合成" : "") + " · 再按快门停止"
        }
        if camera.captureMode == .photo && camera.effectiveDriveMode == .burst && camera.burstShotsTaken == nil {
            return "按住快门连拍（最多 \(CameraManager.burstLimit) 张）"
        }
        switch camera.captureMode {
        case .photo:
            return nil
        case .longExposure:
            if camera.longExposureProgress != nil { return "合成中…再按快门可提前结束" }
            if camera.isProcessing { return "正在保存…" }
            if camera.longExposureBlend == .night { return "夜景：建议 2~4s · 尽量拿稳 · 按下后 2 秒开始" }
            return (camera.longExposureHandheld ? "手持对齐已开" : "建议上三脚架") + " · 按下后 2 秒开始"
        case .bokeh:
            return camera.isProcessing ? "正在合成虚化…" : "点画面选择合焦主体 · 拍摄后合成虚化"
        case .bracket:
            if camera.isProcessing { return "正在对齐并合成 HDR…" }
            let spread = String(format: "%g", camera.bracketSpread)
            return "一次拍 3 张：-\(spread) / 0 / +\(spread) EV" + (camera.bracketMergeHDR ? " · 自动合成 HDR" : "")
        }
    }

    // MARK: - 拍摄模式 & 快门按钮

    private var modePicker: some View {
        HStack(spacing: 20) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { camera.captureMode = mode }
                } label: {
                    Text(mode.name)
                        .font(.footnote.bold())
                        .foregroundStyle(camera.captureMode == mode ? .yellow : .white.opacity(0.7))
                }
            }
        }
        .disabled(camera.longExposureProgress != nil || camera.countdown != nil
                  || camera.intervalShotsTaken != nil || camera.burstShotsTaken != nil)
    }

    @ViewBuilder
    private var shutterButtonLabel: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.35), lineWidth: 4).frame(width: 72, height: 72)
            if let progress = camera.longExposureProgress {
                // 慢门进度环 + 红色停止方块
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 26, height: 26)
            } else if let taken = camera.intervalShotsTaken {
                // 间隔拍摄中：红色停止方块 + 进度
                RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 26, height: 26)
                Text(camera.intervalCount > 0 ? "\(taken)/\(camera.intervalCount)" : "\(taken)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .offset(y: 50)
            } else if let taken = camera.burstShotsTaken {
                Circle().fill(Color.white.opacity(0.6)).frame(width: 58, height: 58)
                Text("\(taken)").font(.title3.monospacedDigit().bold()).foregroundStyle(.black)
            } else if camera.isProcessing {
                ProgressView().tint(.white)
            } else {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                Circle()
                    .fill(camera.captureMode == .longExposure ? Color.red : Color.white)
                    .frame(width: 58, height: 58)
                if camera.countdown != nil {
                    Image(systemName: "xmark").font(.title2.bold()).foregroundStyle(.white)
                }
            }
        }
    }
}

// MARK: - 对焦放大镜

private struct FocusLoupe: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1.0, orientation: .right)
            .resizable()
            .interpolation(.none)   // 不插值，像素边缘保持锐利，合焦与否一眼看出
            .scaledToFill()
            .frame(width: 180, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(Color.yellow, lineWidth: 1.5)
            )
            .overlay(alignment: .topLeading) {
                Text("对焦放大")
                    .font(.caption2.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.yellow)
                    .clipShape(Capsule())
                    .padding(6)
            }
            .shadow(radius: 8)
    }
}

// MARK: - 点击对焦取景框

private struct FocusReticle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 72, height: 72)
    }
}

// MARK: - RGB 直方图（Canvas 绘制三条折线）

struct HistogramView: View {
    let data: HistogramData

    var body: some View {
        Canvas { context, size in
            drawChannel(data.r, color: .red, in: &context, size: size)
            drawChannel(data.g, color: .green, in: &context, size: size)
            drawChannel(data.b, color: .blue, in: &context, size: size)
        }
    }

    private func drawChannel(_ values: [Float], color: Color,
                             in context: inout GraphicsContext, size: CGSize) {
        guard values.count > 1 else { return }
        var path = Path()
        let stepX = size.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let point = CGPoint(x: CGFloat(i) * stepX,
                                y: size.height * (1 - CGFloat(v)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1)
    }
}

// MARK: - 三分线网格

private struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            let path = Path { p in
                for i in 1...2 {
                    let x = size.width * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    let y = size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
        }
    }
}

// MARK: - 水平仪：固定中心刻度 + 随倾斜角旋转的动态线，重合时变绿代表端平

private struct LevelOverlay: View {
    let rollDegrees: Double

    /// 相对最近的横 / 竖持姿态的偏差：横拍时 roll≈±90°，偏差才是真正的"歪了多少"
    private var deviation: Double { rollDegrees - 90 * (rollDegrees / 90).rounded() }
    private var isLevel: Bool { abs(deviation) < 1.0 }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                // 固定参考刻度
                Rectangle()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 24, height: 1.5)
                    .position(center)

                // 跟随倾斜角旋转的水平线，端平时和参考刻度重合并变绿
                Rectangle()
                    .fill(isLevel ? Color.green : Color.white)
                    .frame(width: 90, height: 1.5)
                    .rotationEffect(.degrees(-rollDegrees))
                    .position(center)

                Text(String(format: "%.0f°", abs(deviation)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isLevel ? .green : .white)
                    .position(x: center.x, y: center.y + 20)
            }
            .animation(.easeOut(duration: 0.1), value: rollDegrees)
        }
    }
}
