import SwiftUI

@main
struct NearChatApp: App {
    @StateObject private var model: LabModel
    init() {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "local.nearchat.uxqa", ProcessInfo.processInfo.arguments.contains("--ux-fixture") {
            do {
                let fixture = try UXFixture.make()
                _model = StateObject(wrappedValue: LabModel(previewEngine: fixture))
            }
            catch { fatalError("UX fixture failed: \(error)") }
            return
        }
        #endif
        _model = StateObject(wrappedValue: LabModel())
    }
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            LabView(model: model)
                .tint(.teal)
                .onChange(of: phase) { _, next in model.sceneChanged(next) }
        }
    }
}
