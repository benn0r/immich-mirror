#if DEBUG
  import Foundation

  /// Fictional account and sync state for screenshots: launch a Debug build with `-demo`.
  /// Nothing is read from the photo library, sent to a server or saved to the Keychain.
  enum DemoData {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    /// `-demo-screen dry-run|report|settings` shows that state at launch (for screenshots); default is a running sync.
    static var screen: String? {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "-demo-screen"), index + 1 < arguments.count else {
        return nil
      }
      return arguments[index + 1]
    }

    static let session = StoredSession(
      serverURL: URL(string: "https://photos.example.com")!, email: "alex@example.com",
      userName: "Alex Morgan", accessToken: "demo")

    static let mirroredCount = 12_483

    static var lastSync: String {
      let date = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
      let at = Calendar.current.date(bySettingHour: 22, minute: 14, second: 0, of: date) ?? date
      let f = ISO8601DateFormatter()
      f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return f.string(from: at)
    }

    static var progress: SyncProgress {
      SyncProgress(
        phase: String(localized: "Uploading new photos"), done: 128, total: 342,
        detail: String(localized: "\("IMG_4821.HEIC") · uploading \(64)%"))
    }

    static var report: SyncReport {
      var r = SyncReport(dryRun: false)
      r.localCount = 12_611
      r.newFound = 57
      r.uploaded = 54
      r.adopted = 3
      r.favoritesUpdated = 4
      r.changedFound = 2
      r.reuploaded = 2
      r.trashed = 9
      r.albumsCreated = 1
      r.albumAssetsAdded = 23
      r.placed = [
        .init(filename: "IMG_4877.HEIC", immichId: "demo-1", how: String(localized: "uploaded")),
        .init(filename: "IMG_4876.HEIC", immichId: "demo-2", how: String(localized: "live photo")),
        .init(filename: "IMG_4875.MOV", immichId: "demo-3", how: String(localized: "uploaded")),
      ]
      return r
    }

    static var dryRunReport: SyncReport {
      var r = SyncReport(dryRun: true)
      r.localCount = 12_611
      r.newFound = 342
      r.estimatedUploadBytes = 4_310_000_000
      r.sampled = 200
      r.sampleAdopt = 18
      r.sampleUpload = 182
      r.changedFound = 6
      r.pendingDeletions = 9
      r.albumsCreated = 3
      r.albumsRenamed = 1
      return r
    }
  }
#endif
