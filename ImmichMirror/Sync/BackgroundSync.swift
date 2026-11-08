import BackgroundTasks
import Foundation

/// Opportunistic background mirroring via BGProcessingTask (runs when iOS decides —
/// typically overnight while charging and on Wi-Fi). Never confirms mass deletions.
enum BackgroundSync {
  static let identifier = "ch.benn0r.immichmirror.sync"

  static func register() {
    if #available(iOS 26.0, *) { ContinuedSync.register() }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      handle(task as! BGProcessingTask)
    }
  }

  static func schedule() {
    let req = BGProcessingTaskRequest(identifier: identifier)
    req.requiresNetworkConnectivity = true
    req.requiresExternalPower = true
    req.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
    try? BGTaskScheduler.shared.submit(req)
  }

  static func cancel() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
  }

  private static func handle(_ task: BGProcessingTask) {
    schedule()  // keep the chain going
    var settings = SyncSettings.load()
    guard UserDefaults.standard.bool(forKey: "backgroundSync"), !settings.dryRun,
      let s = Keychain.load(), let store = try? MirrorStore(userId: s.email)
    else {
      task.setTaskCompleted(success: true)
      return
    }
    settings.dryRun = false
    let client = ImmichClient(baseURL: s.serverURL, token: s.accessToken)
    let engine = SyncEngine(
      client: client, store: store, settings: settings, onProgress: { _ in }, onLog: { _ in })
    let work = Task {
      let ok = (try? await engine.run(confirmMassDeletion: false)) != nil
      task.setTaskCompleted(success: ok)
    }
    task.expirationHandler = { work.cancel() }
  }
}
