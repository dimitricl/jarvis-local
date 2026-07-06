import SwiftUI
import os.log

@main
struct JarvisLocalApp: App {
    @State private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .environment(Settings.shared)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    await viewModel.loadConversations()
                    logVersion()
                    Task.detached { checkEdgeTTSAvailability() }
                }
        }
        .windowResizability(.contentSize)
    }

    private func logVersion() {
        let version = Settings.shared.currentVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        os_log("JarvisLocal v%@ (%@) — https://github.com/dimitricl/jarvis-local", log: .default, type: .info, version, build)
        print("🚀 JarvisLocal v\(version) (build \(build))")
    }

    private nonisolated func checkEdgeTTSAvailability() {
        let settings = Settings.shared
        if settings.ttsEngine == .edgeTTS, !settings.edgeTTSAvailable {
            os_log("⚠ edge-tts est sélectionné mais n'est pas installé. Fallback sur synthèse macOS.")
        }
    }
}
