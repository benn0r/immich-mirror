import BackgroundTasks
import Foundation

/// iOS 26 continued processing: a sync started in the app keeps running after the user leaves it,
/// with system-provided progress UI (lock screen / Dynamic Island). iOS may still stop it under
/// load; the next run resumes where it left off.
@available(iOS 26.0, *)
enum ContinuedSync {
  static let identifier = "ch.benn0r.immichmirror.continued"

  /// Set by AppModel right before submitting; called on the main queue when iOS starts the task.
  static var onLaunch: ((BGContinuedProcessingTask) -> Void)?

  static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
      guard let task = task as? BGContinuedProcessingTask, let onLaunch else {
        task.setTaskCompleted(success: false)
        return
      }
      onLaunch(task)
    }
  }

  /// Asks iOS to run the sync as a continued task right now. Returns false if it refused,
  /// in which case the caller runs the sync in the foreground as before.
  static func submit() -> Bool {
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: "Immich Mirror", subtitle: "Starting sync…")
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
      return true
    } catch {
      return false
    }
  }

  static func report(_ task: BGContinuedProcessingTask, _ p: SyncProgress) {
    if p.total > 0 {
      task.progress.totalUnitCount = Int64(p.total)
      task.progress.completedUnitCount = Int64(min(p.done, p.total))
      task.updateTitle("Immich Mirror", subtitle: "\(p.phase) · \(p.done) / \(p.total)")
    } else {
      task.updateTitle("Immich Mirror", subtitle: p.phase)
    }
  }
}
