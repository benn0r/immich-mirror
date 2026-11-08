import BackgroundTasks
import Foundation
import Observation
import Photos
import UIKit

@MainActor
@Observable
final class AppModel {
  var session: StoredSession? = Keychain.load()
  var settings = SyncSettings.load() { didSet { settings.save() } }
  var backgroundSyncEnabled = UserDefaults.standard.bool(forKey: "backgroundSync") {
    didSet {
      UserDefaults.standard.set(backgroundSyncEnabled, forKey: "backgroundSync")
      if backgroundSyncEnabled { BackgroundSync.schedule() } else { BackgroundSync.cancel() }
    }
  }

  var notifyOnFinish = SyncNotifier.isEnabled {
    didSet {
      SyncNotifier.isEnabled = notifyOnFinish
      if notifyOnFinish { Task { await SyncNotifier.requestPermissionIfNeeded() } }
    }
  }

  var photoStatus: PHAuthorizationStatus = PhotoLibrary.status
  var isRunning = false
  var progress: SyncProgress?
  var lastReport: SyncReport?
  var lastError: String?
  var log: [LogLine] = []
  var mirroredCount = 0
  var lastSync: String?

  struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
  }

  private var task: Task<Void, Never>?
  /// The running BGContinuedProcessingTask (iOS 26+), typed loosely to keep iOS 17 support.
  private var continuedTask: AnyObject?
  var runsInBackground: Bool { continuedTask != nil }

  var client: ImmichClient? {
    session.map { ImmichClient(baseURL: $0.serverURL, token: $0.accessToken) }
  }

  // MARK: Auth

  func signIn(server: String, email: String, password: String) async throws {
    guard let url = ImmichClient.normalize(server) else { throw ImmichError.badURL }
    let anon = ImmichClient(baseURL: url, token: nil)
    let version = try await anon.serverVersion()
    let login = try await anon.login(email: email, password: password)
    let s = StoredSession(
      serverURL: url, email: login.userEmail, userName: login.name, accessToken: login.accessToken)
    Keychain.save(s)
    session = s
    append("Signed in as \(login.name) on Immich \(version.string)")
    refreshCounts()
  }

  func signOut() async {
    cancel()
    if let client { try? await client.logout() }
    Keychain.clear()
    BackgroundSync.cancel()
    session = nil
    lastReport = nil
  }

  // MARK: Sync

  func requestPhotoAccess() async {
    photoStatus = await PhotoLibrary.requestAccess()
  }

  func refreshCounts() {
    guard let s = session, let store = try? MirrorStore(userId: s.email) else { return }
    mirroredCount = (try? store.assetCount()) ?? 0
    lastSync = try? store.get("lastSync")
  }

  func resetMapping() {
    guard let s = session, let store = try? MirrorStore(userId: s.email) else { return }
    try? store.reset()
    append("Local mapping reset — next sync re-adopts server copies by checksum")
    refreshCounts()
  }

  func sync(confirmMassDeletion: Bool = false) {
    guard !isRunning, session != nil else { return }
    isRunning = true
    lastError = nil
    if !settings.dryRun { Task { await SyncNotifier.requestPermissionIfNeeded() } }
    // Dry runs are quick — only real syncs go to the background.
    if #available(iOS 26.0, *), !settings.dryRun {
      ContinuedSync.onLaunch = { [weak self] bgTask in
        self?.start(confirmMassDeletion: confirmMassDeletion, continued: bgTask)
      }
      if ContinuedSync.submit() {
        progress = SyncProgress(phase: "Starting in background…")
        return
      }
      append("Background sync not available right now — running in the foreground")
    }
    start(confirmMassDeletion: confirmMassDeletion, continued: nil)
  }

  private func start(confirmMassDeletion: Bool, continued: AnyObject?) {
    guard let s = session, let client else {
      isRunning = false
      return
    }
    continuedTask = continued
    if #available(iOS 26.0, *) { ContinuedSync.resetProgress() }
    if #available(iOS 26.0, *), let bg = continued as? BGContinuedProcessingTask {
      bg.expirationHandler = { [weak self] in
        Task { @MainActor in
          SyncLog.write("EXPIRED by iOS · \(SyncLog.conditions()) · \(self?.progressLine ?? "")")
          self?.append("iOS stopped the background sync — it resumes on the next run")
          if self?.backgroundSyncEnabled == true { BackgroundSync.schedule() }
          self?.cancel(reason: "expired by iOS")
        }
      }
    }
    // Foreground only: iOS suspends uploads when the screen locks.
    UIApplication.shared.isIdleTimerDisabled = continued == nil
    let settings = self.settings
    cancelReason = nil
    let started = Date()
    SyncLog.write(
      "START \(settings.dryRun ? "dry run" : "sync") · \(continued != nil ? "background task" : "foreground") · \(SyncLog.conditions())"
    )
    heartbeat?.cancel()
    heartbeat = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        guard let self, self.isRunning else { return }
        SyncLog.write("… \(self.progressLine) · \(SyncLog.conditions())")
      }
    }
    task = Task {
      var success = false
      defer {
        Task { @MainActor in
          UIApplication.shared.isIdleTimerDisabled = false
          if #available(iOS 26.0, *), let bg = self.continuedTask as? BGContinuedProcessingTask {
            bg.setTaskCompleted(success: success)
          }
          self.continuedTask = nil
          self.heartbeat?.cancel()
          self.isRunning = false
          self.progress = nil
          self.refreshCounts()
        }
      }
      do {
        let store = try MirrorStore(userId: s.email)
        let engine = SyncEngine(
          client: client, store: store, settings: settings,
          onProgress: { p in Task { @MainActor in self.apply(p) } },
          onLog: { line in Task { @MainActor in self.append(line) } })
        let report = try await engine.run(confirmMassDeletion: confirmMassDeletion)
        self.lastReport = report
        success = !report.cancelled
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        SyncLog.write(
          "END \(report.cancelled ? "cancelled (\(self.cancelReason ?? "unknown"))" : "finished") after \(minutes) min · uploaded \(report.uploaded) adopted \(report.adopted) trashed \(report.trashed) failures \(report.failures.count) · \(SyncLog.conditions())"
        )
        for f in report.failures.prefix(50) { SyncLog.write("  failure: \(f)") }
        if UIApplication.shared.applicationState != .active { SyncNotifier.notify(report) }
        if !report.failures.isEmpty {
          self.append("\(report.failures.count) items failed — see report")
        }
      } catch ImmichError.unauthorized {
        SyncLog.write("END error: session expired (401) · \(SyncLog.conditions())")
        self.lastError = ImmichError.unauthorized.localizedDescription
        if UIApplication.shared.applicationState != .active {
          SyncNotifier.notify(error: ImmichError.unauthorized)
        }
        Keychain.clear()
        self.session = nil
      } catch {
        self.lastError = error.localizedDescription
        self.append("Error: \(error.localizedDescription)")
        SyncLog.write(
          "END error after \(Int(Date().timeIntervalSince(started) / 60)) min: \(error) · \(SyncLog.conditions())"
        )
        if UIApplication.shared.applicationState != .active { SyncNotifier.notify(error: error) }
      }
    }
  }

  var progressLine: String {
    guard let p = progress else { return "no progress" }
    return "\(p.phase) \(p.done)/\(p.total)\(p.detail.map { " [\($0)]" } ?? "")"
  }

  /// Why the current run is being cancelled (for the persistent log).
  private var cancelReason: String?
  private var heartbeat: Task<Void, Never>?

  func cancel(reason: String = "stopped by user") {
    cancelReason = reason
    task?.cancel()
  }

  /// Progress events arrive out of order from parallel downloads — never move the bar backwards within a phase.
  private func apply(_ p: SyncProgress) {
    guard isRunning else { return }
    if p.phase.isEmpty {
      // Detail-only event (upload percentage) for whatever phase is running.
      if var cur = progress {
        cur.detail = p.detail
        progress = cur
      }
    } else if var cur = progress, cur.phase == p.phase {
      cur.done = max(cur.done, p.done)
      cur.total = p.total
      if p.detail != nil || p.done > (progress?.done ?? 0) { cur.detail = p.detail }
      progress = cur
    } else {
      progress = p
    }
    if #available(iOS 26.0, *), let bg = continuedTask as? BGContinuedProcessingTask,
      let cur = progress
    {
      ContinuedSync.report(bg, cur, tick: p.tick)
    }
  }

  func append(_ s: String) {
    SyncLog.write(s)
    log.insert(LogLine(text: s), at: 0)
    if log.count > 300 { log.removeLast(log.count - 300) }
  }
}
