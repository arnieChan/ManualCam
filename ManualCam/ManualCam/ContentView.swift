import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        Group {
            switch camera.authorizationState {
            case .authorized:
                CameraView(camera: camera)
            case .denied:
                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("需要相机权限才能使用")
                        .font(.headline)
                    Button("去系统设置开启") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            case .notDetermined:
                ProgressView("正在请求相机权限…")
            }
        }
        .onAppear { camera.start() }
        .alert("出错了", isPresented: .constant(camera.errorMessage != nil)) {
            Button("好") { camera.errorMessage = nil }
        } message: {
            Text(camera.errorMessage ?? "")
        }
    }
}
