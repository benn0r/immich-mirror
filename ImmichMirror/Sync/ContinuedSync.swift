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
      identifier: identifier, title: "Photo Mirror", subtitle: String(localized: "Starting sync…"))
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
      return true
    } catch {
      return false
    }
  }

  // iOS expires a continued task whose progress stops moving, so progress is one counter that only
  // grows across all phases, and download/upload activity inside an item ("ticks") advances it too.
  private static var base = 0  // units completed in earlier phases
  private static var phase = ""
  private static var phaseDone = 0
  private static var ticks = 0  // activity since the last completed item (max 99)
  private static let unit: Int64 = 100

  static func resetProgress() {
    base = 0
    phase = ""
    phaseDone = 0
    ticks = 0
  }

  static func report(_ task: BGContinuedProcessingTask, _ p: SyncProgress, tick: Bool) {
    if p.phase != phase {
      base += phaseDone
      phase = p.phase
      phaseDone = 0
      ticks = 0
    }
    if p.done > phaseDone {
      phaseDone = p.done
      ticks = 0
    } else if tick {
      ticks = min(ticks + 1, 99)
    }
    let done = Int64(base + phaseDone) * unit + Int64(ticks)
    let total = Int64(base + max(p.total, phaseDone + 1)) * unit
    task.progress.totalUnitCount = max(total, done + 1)
    task.progress.completedUnitCount = done
    let counts = p.total > 0 ? " · \(p.done) / \(p.total)" : ""
    task.updateTitle("Photo Mirror", subtitle: p.phase + counts)
  }
}
