import SwiftUI
import Photos
import ImageIO

// MARK: - 本 App 拍摄记录

/// 记下本 App 存进相册的照片 ID（新的在前）。App 内相册只列这些，不会翻用户的其他照片。
/// iOS 在"有限访问"下也会自动把 App 自己创建的照片放进可见范围，所以选"仅所选照片"同样能看
final class CaptureLibrary: ObservableObject {
    static let shared = CaptureLibrary()
    private static let key = "capturedAssetIDs.v1"
    private static let limit = 5000

    @Published private(set) var ids: [String]

    private init() {
        ids = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func add(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
        UserDefaults.standard.set(ids, forKey: Self.key)
    }

    /// 在系统相册里已被删除的照片，从记录里清掉
    func prune(keeping existing: Set<String>) {
        let kept = ids.filter { existing.contains($0) }
        guard kept.count != ids.count else { return }
        ids = kept
        UserDefaults.standard.set(ids, forKey: Self.key)
    }
}

// MARK: - 相册网格

struct GalleryView: View {
    /// 没有相册读取权限时，至少能看刚拍的那一张
    let fallback: UIImage?
    let onClose: () -> Void
    @State private var showFallback = false
    @ObservedObject private var library = CaptureLibrary.shared
    @State private var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var assets: [PHAsset] = []
    @State private var selected: PHAsset?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ManualCam 拍摄")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", action: onClose)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("\(assets.count) 张").font(.caption).foregroundStyle(.secondary)
                    }
                }
        }
        .preferredColorScheme(.dark)
        .task {
            if status == .notDetermined {
                status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            reload()
        }
        .onChange(of: library.ids) { _, _ in reload() }
        .fullScreenCover(item: $selected) { asset in
            PhotoPager(assets: assets, initial: asset) { selected = nil }
        }
        .fullScreenCover(isPresented: $showFallback) {
            if let fallback {
                PhotoViewerView(image: fallback) { showFallback = false }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .authorized, .limited:
            if assets.isEmpty {
                ContentUnavailableView("还没有照片", systemImage: "camera",
                                       description: Text("用 ManualCam 拍的照片会出现在这里"))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            Button { selected = asset } label: {
                                AssetThumbnail(asset: asset)
                            }
                        }
                    }
                }
            }
        default:
            ContentUnavailableView {
                Label("需要相册读取权限", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text("App 内相册只显示本 App 拍的照片。可在设置里选择「仅所选照片」，本 App 拍的照片会自动可见。")
            } actions: {
                Button("去系统设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                if fallback != nil {
                    Button("查看刚拍的一张") { showFallback = true }
                }
            }
        }
    }

    private func reload() {
        guard status == .authorized || status == .limited, !library.ids.isEmpty else {
            assets = []
            return
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: library.ids, options: nil)
        var found: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in found.append(asset) }
        // 完整权限下能确认哪些已在系统相册删除；有限权限下看不到不代表被删了，不清理
        if status == .authorized {
            library.prune(keeping: Set(found.map(\.localIdentifier)))
        }
        assets = found.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

private struct AssetThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var hasRAW = false

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if hasRAW {
                    Text("RAW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.yellow)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            .task(id: asset.localIdentifier) {
                hasRAW = PHAssetResource.assetResources(for: asset).contains { $0.type == .alternatePhoto }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 300, height: 300),
                                                      contentMode: .aspectFill, options: options) { result, _ in
                    if let result { image = result }
                }
            }
    }
}

// MARK: - 大图翻页 + 拍摄参数

private struct PhotoPager: View {
    let assets: [PHAsset]
    let onClose: () -> Void
    @State private var current: String
    @State private var showInfo = false

    init(assets: [PHAsset], initial: PHAsset, onClose: @escaping () -> Void) {
        self.assets = assets
        self.onClose = onClose
        _current = State(initialValue: initial.localIdentifier)
    }

    private var currentAsset: PHAsset? { assets.first { $0.localIdentifier == current } }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $current) {
                ForEach(assets, id: \.localIdentifier) { asset in
                    AssetFullImage(asset: asset).tag(asset.localIdentifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 30))
                    }
                    Spacer()
                    Button { withAnimation { showInfo.toggle() } } label: {
                        Image(systemName: showInfo ? "info.circle.fill" : "info.circle").font(.system(size: 30))
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding()
                Spacer()
                if showInfo, let asset = currentAsset {
                    PhotoInfoPanel(asset: asset)
                        .id(asset.localIdentifier)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct AssetFullImage: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableScrollView(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: asset.localIdentifier) {
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            // 不取原尺寸：4800 万像素原图解码太占内存，长边 4000 像素放大到 100x 也够看清
            let side: CGFloat = 4000
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { result, _ in
                if let result { image = result }
            }
        }
    }
}

/// 从照片 EXIF 读出拍摄参数
private struct PhotoInfoPanel: View {
    let asset: PHAsset
    @State private var rows: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Text(row.1).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .font(.footnote)
            }
            if rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(12)
        .task { load() }
    }

    private func load() {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            var result = PhotoInfoPanel.describe(data: data)
            let resources = PHAssetResource.assetResources(for: asset)
            let format = resources.contains { $0.type == .alternatePhoto } ? "HEIF + RAW (DNG)" : "HEIF"
            result.append(("格式", format))
            if let date = asset.creationDate {
                result.insert(("时间", date.formatted(date: .abbreviated, time: .standard)), at: 0)
            }
            rows = result
        }
    }

    static func describe(data: Data?) -> [(String, String)] {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return [("参数", "读取失败")]
        }
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var rows: [(String, String)] = []

        var exposure: [String] = []
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            exposure.append(t >= 0.3 ? String(format: "%gs", (t * 10).rounded() / 10) : ExposureStops.shutterLabel(Float(t)))
        }
        if let f = exif[kCGImagePropertyExifFNumber as String] as? Double {
            exposure.append(String(format: "f/%.1f", f))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first {
            exposure.append("ISO \(iso)")
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double, abs(bias) > 0.01 {
            exposure.append(String(format: "%+.1f EV", bias))
        }
        if !exposure.isEmpty { rows.append(("曝光", exposure.joined(separator: "  "))) }

        var lens: [String] = []
        if let mm35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
            lens.append("等效 \(mm35)mm")
        }
        if let model = (exif[kCGImagePropertyExifLensModel as String] as? String)
            ?? (exifAux[kCGImagePropertyExifAuxLensModel as String] as? String) {
            lens.append(model)
        }
        if !lens.isEmpty { rows.append(("镜头", lens.joined(separator: " · "))) }

        if let w = exif[kCGImagePropertyExifPixelXDimension as String] as? Int,
           let h = exif[kCGImagePropertyExifPixelYDimension as String] as? Int {
            rows.append(("尺寸", "\(w) × \(h)（\(String(format: "%.1f", Double(w * h) / 1_000_000)) MP）"))
        }
        if let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
            rows.append(("机型", model))
        }
        if let note = tiff[kCGImagePropertyTIFFImageDescription as String] as? String, !note.isEmpty {
            rows.append(("备注", note))
        }
        return rows
    }
}
