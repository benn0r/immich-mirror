import Foundation
import OSLog
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
    queue.async { append(line) }
  }

  private static let logger = Logger(subsystem: "ch.benn0r.immichmirror", category: "synclog")
  /// The last failure writing the file (shown once per kind in the console, never silently lost).
  private static var lastFailure: String?

  /// Appends with plain POSIX calls: O_APPEND writes are atomic and need no seek, and every failure
  /// is reported with its errno instead of disappearing in a `try?`.
  private static func append(_ line: String) {
    let url = self.url
    let fm = FileManager.default
    if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
      let old = url.deletingLastPathComponent().appendingPathComponent("sync.1.log")
      try? fm.removeItem(at: old)
      try? fm.moveItem(at: url, to: old)
    }
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return fail("open", errno, line) }
    defer { close(fd) }
    let bytes = Array(line.utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    if written != bytes.count { return fail("write", errno, line) }
    if lastFailure != nil {
      lastFailure = nil
      logger.notice("sync.log writable again")
    }
    // Writable by background runs while the phone is locked (set once per launch).
    if !protectionSet {
      protectionSet = true
      try? fm.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    }
  }
  private static var protectionSet = false

  private static func fail(_ call: String, _ code: Int32, _ line: String) {
    let reason = "\(call) failed: \(String(cString: strerror(code))) (errno \(code))"
    if reason != lastFailure {
      lastFailure = reason
      logger.error("sync.log \(reason, privacy: .public)")
      FileHandle.standardError.write(Data("sync.log \(reason)\n".utf8))
    }
    logger.info("\(line, privacy: .public)")
  }

  /// The newest entries, oldest first, for the in-app log. Per-minute progress heartbeats are left out.
  static func recent(limit: Int) -> [(date: Date, text: String)] {
    queue.sync {
      guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
      defer { try? h.close() }
      let end = (try? h.seekToEnd()) ?? 0
      let tail: UInt64 = 256 * 1024
      try? h.seek(toOffset: end > tail ? end - tail : 0)
      let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
      var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
      if end > tail { lines = Array(lines.dropFirst()) }  // first line may be cut off
      let entries: [(date: Date, text: String)] = lines.compactMap { line in
        guard let space = line.firstIndex(of: " "),
          let date = formatter.date(from: String(line[..<space]))
        else { return nil }
        let message = String(line[line.index(after: space)...])
        return message.hasPrefix("… ") ? nil : (date, message)
      }
      return Array(entries.suffix(limit))
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
