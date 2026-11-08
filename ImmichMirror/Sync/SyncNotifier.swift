import Foundation
import UserNotifications

/// Local notification with a summary when a real (non-dry) sync ends while the app is not in front:
/// continued background runs, nightly runs, or when the user switched away.
enum SyncNotifier {
  private static let enabledKey = "notifyOnFinish"

  static var isEnabled: Bool {
    get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  /// Asks once (the system remembers the answer); later calls are no-ops.
  static func requestPermissionIfNeeded() async {
    guard isEnabled else { return }
    let center = UNUserNotificationCenter.current()
    guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  static func notify(_ report: SyncReport) {
    guard !report.dryRun else { return }
    let (title, body) = summary(report)
    post(title: title, body: body)
  }

  static func notify(error: Error) {
    post(title: "Sync failed", body: error.localizedDescription)
  }

  private static func post(title: String, body: String) {
    guard isEnabled else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.threadIdentifier = "sync"
    let request = UNNotificationRequest(
      identifier: "sync-\(UUID().uuidString)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  // MARK: - Text (pure, unit-tested)

  /// Anything worth telling the user about (used to keep nightly runs quiet when nothing changed).
  static func hasNews(_ r: SyncReport) -> Bool {
    r.uploaded + r.adopted + r.reuploaded + r.restored + r.favoritesUpdated + r.trashed
      + r.albumsCreated
      + r.albumsRenamed + r.albumsDeleted + r.albumAssetsAdded + r.albumAssetsRemoved > 0
      || !r.failures.isEmpty || r.deletionBlockedReason != nil || r.cancelled
  }

  static func summary(_ r: SyncReport) -> (title: String, body: String) {
    let title =
      r.cancelled
      ? "Sync stopped" : (r.failures.isEmpty ? "Sync finished" : "Sync finished with errors")
    var parts: [String] = []
    func add(_ n: Int, _ one: String, _ many: String) {
      if n > 0 { parts.append("\(n.formatted()) \(n == 1 ? one : many)") }
    }
    add(r.uploaded, "photo uploaded", "photos uploaded")
    add(r.adopted, "already on server", "already on server")
    add(r.reuploaded, "edit updated", "edits updated")
    add(r.restored, "restored from trash", "restored from trash")
    add(r.favoritesUpdated, "favorite updated", "favorites updated")
    add(r.trashed, "moved to trash", "moved to trash")
    add(r.albumsCreated, "album created", "albums created")
    add(r.albumsRenamed, "album renamed", "albums renamed")
    add(r.albumsDeleted, "album deleted", "albums deleted")
    let albumChanges = r.albumAssetsAdded + r.albumAssetsRemoved
    if albumChanges > 0, r.albumsCreated == 0 { add(albumChanges, "album change", "album changes") }

    var lines: [String] = []
    lines.append(parts.isEmpty ? "Everything up to date." : parts.joined(separator: " · "))
    if r.deletionBlockedReason != nil, r.pendingDeletions > 0 {
      lines.append("\(r.pendingDeletions.formatted()) deletions wait for your confirmation.")
    }
    if !r.failures.isEmpty {
      lines.append(
        "\(r.failures.count.formatted()) \(r.failures.count == 1 ? "item" : "items") failed.")
    }
    if r.cancelled {
      lines.append("Continues where it left off — open the app and tap Sync Now.")
    } else {
      lines.append("\(r.mirroredAfter.formatted()) of \(r.localCount.formatted()) photos mirrored.")
    }
    return (title, lines.joined(separator: "\n"))
  }
}
