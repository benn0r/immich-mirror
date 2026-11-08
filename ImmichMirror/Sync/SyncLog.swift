import Foundation
import UIKit

/// Persistent sync log (Application Support/sync.log, rotated at 2 MB) so a run that ends while the
/// app is in the background can be diagnosed afterwards. Read it from a Mac with:
///   xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///     --domain-identifier ch.benn0r.immichmirror --source "Library/Application Support/sync.log" \
///     --destination sync.log
enum SyncLog {
  private static let queue = DispatchQueue(label: "ch.benn0r.immichmirror.synclog")
  private static let maxBytes = 2 * 1024 * 1024
  private static let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static var url: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("sync.log")
  }

  static func write(_ message: String) {
    let line = "\(formatter.string(from: Date())) \(message)\n"
    queue.async {
      let url = self.url
      let fm = FileManager.default
      if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
        let old = url.deletingLastPathComponent().appendingPathComponent("sync.1.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
      }
      if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
      guard let h = try? FileHandle(forWritingTo: url) else { return }
      defer { try? h.close() }
      _ = try? h.seekToEnd()
      try? h.write(contentsOf: Data(line.utf8))
    }
  }

  /// Device conditions that make iOS stop background work.
  @MainActor static func conditions() -> String {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let battery = device.batteryLevel < 0 ? "?" : "\(Int(device.batteryLevel * 100))%"
    let charging: String
    switch device.batteryState {
    case .charging: charging = "charging"
    case .full: charging = "full"
    case .unplugged: charging = "unplugged"
    default: charging = "unknown"
    }
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "SERIOUS"
    case .critical: thermal = "CRITICAL"
    @unknown default: thermal = "?"
    }
    let state: String
    switch UIApplication.shared.applicationState {
    case .active: state = "foreground"
    case .inactive: state = "inactive"
    case .background: state = "background"
    @unknown default: state = "?"
    }
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled ? " lowPower" : ""
    return "app=\(state) battery=\(battery) \(charging) thermal=\(thermal)\(lowPower)"
  }
}
