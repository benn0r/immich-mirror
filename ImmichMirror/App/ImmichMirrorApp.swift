import SwiftUI

@main
struct ImmichMirrorApp: App {
  @State private var model = AppModel()
  @Environment(\.scenePhase) private var phase

  init() { BackgroundSync.register() }

  var body: some Scene {
    WindowGroup {
      Group {
        if model.session == nil { LoginView() } else { HomeView() }
      }
      .environment(model)
      .onAppear { model.refreshCounts() }
    }
    .onChange(of: phase) { _, new in
      if new == .background, model.backgroundSyncEnabled { BackgroundSync.schedule() }
    }
  }
}
