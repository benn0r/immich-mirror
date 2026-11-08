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
    post(title: String(localized: "Sync failed"), body: error.localizedDescription)
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
      ? String(localized: "Sync stopped")
      : (r.failures.isEmpty
        ? String(localized: "Sync finished") : String(localized: "Sync finished with errors"))
    // One localized key per count so every language gets its own plural forms.
    var parts: [String] = []
    if r.uploaded > 0 { parts.append(String(localized: "\(r.uploaded) photos uploaded")) }
    if r.adopted > 0 { parts.append(String(localized: "\(r.adopted) already on server")) }
    if r.reuploaded > 0 { parts.append(String(localized: "\(r.reuploaded) edits updated")) }
    if r.restored > 0 { parts.append(String(localized: "\(r.restored) restored from trash")) }
    if r.favoritesUpdated > 0 {
      parts.append(String(localized: "\(r.favoritesUpdated) favorites updated"))
    }
    if r.trashed > 0 { parts.append(String(localized: "\(r.trashed) moved to trash")) }
    if r.albumsCreated > 0 { parts.append(String(localized: "\(r.albumsCreated) albums created")) }
    if r.albumsRenamed > 0 { parts.append(String(localized: "\(r.albumsRenamed) albums renamed")) }
    if r.albumsDeleted > 0 { parts.append(String(localized: "\(r.albumsDeleted) albums deleted")) }
    let albumChanges = r.albumAssetsAdded + r.albumAssetsRemoved
    if albumChanges > 0, r.albumsCreated == 0 {
      parts.append(String(localized: "\(albumChanges) album changes"))
    }

    var lines: [String] = []
    lines.append(
      parts.isEmpty ? String(localized: "Everything up to date.") : parts.joined(separator: " · "))
    if r.deletionBlockedReason != nil, r.pendingDeletions > 0 {
      lines.append(String(localized: "\(r.pendingDeletions) deletions wait for your confirmation."))
    }
    if !r.failures.isEmpty {
      lines.append(String(localized: "\(r.failures.count) items failed."))
    }
    if r.cancelled {
      lines.append(
        String(localized: "Continues where it left off — open the app and tap Sync Now."))
    } else {
      let mirrored = r.mirroredAfter.formatted()
      let total = r.localCount.formatted()
      lines.append(String(localized: "\(mirrored) of \(total) photos mirrored."))
    }
    return (title, lines.joined(separator: "\n"))
  }
}
