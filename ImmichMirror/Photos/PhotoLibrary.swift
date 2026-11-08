import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

struct LocalAsset: Equatable {
  var localId: String
  var modifiedAt: Double
  var isFavorite: Bool
}

struct LocalAlbum: Equatable {
  var localId: String
  var name: String  // folder path flattened: "Travel / Japan 2025"
  var assetLocalIds: [String]
}

struct ExportedFile {
  var url: URL
  var filename: String
  var mimeType: String
  var sha1Hex: String
  var sha1Base64: String
}

struct ExportedAsset {
  var localId: String
  var primary: ExportedFile
  var pairedVideo: ExportedFile?  // live photo motion part
  var createdAt: Date
  var modifiedAt: Date
  var isFavorite: Bool
  var durationMs: Int?

  func cleanup() {
    try? FileManager.default.removeItem(at: primary.url)
    if let v = pairedVideo { try? FileManager.default.removeItem(at: v.url) }
  }
}

enum PhotoLibraryError: LocalizedError {
  case notAuthorized(PHAuthorizationStatus)
  case assetMissing(String)
  case noResource(String)

  var errorDescription: String? {
    switch self {
    case .notAuthorized(let s):
      return s == .limited
        ? "Full photo access is required. With limited access every unselected photo would look deleted."
        : "Photo library access not granted."
    case .assetMissing(let id): return "Photo \(id) no longer exists"
    case .noResource(let id): return "No original file for \(id)"
    }
  }
}

enum PhotoLibrary {
  static func requestAccess() async -> PHAuthorizationStatus {
    await PHPhotoLibrary.requestAuthorization(for: .readWrite)
  }

  static var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

  /// Full access is mandatory: with `.limited`, unselected photos would be indistinguishable from deleted ones.
  static func requireFullAccess() throws {
    let s = status
    guard s == .authorized else { throw PhotoLibraryError.notAuthorized(s) }
  }

  static func localAssets() -> [LocalAsset] {
    let opts = PHFetchOptions()
    opts.includeAssetSourceTypes = [.typeUserLibrary]
    let result = PHAsset.fetchAssets(with: opts)
    var out: [LocalAsset] = []
    out.reserveCapacity(result.count)
    result.enumerateObjects { a, _, _ in
      out.append(
        LocalAsset(
          localId: a.localIdentifier,
          modifiedAt: (a.modificationDate ?? a.creationDate ?? .distantPast).timeIntervalSince1970,
          isFavorite: a.isFavorite))
    }
    return out
  }

  /// Sum of the file sizes that `export` would upload (uses PHAssetResource's `fileSize`; metadata only, no download).
  static func estimatedSize(of localIds: [String]) -> Int64 {
    var total: Int64 = 0
    for chunk in localIds.chunked(500) {
      let result = PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: nil)
      result.enumerateObjects { asset, _, _ in
        let res = PHAssetResource.assetResources(for: asset)
        func size(_ types: [PHAssetResourceType]) -> Int64 {
          for t in types {
            if let r = res.first(where: { $0.type == t }) {
              return (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            }
          }
          return 0
        }
        if asset.mediaType == .video {
          total += size([.fullSizeVideo, .video])
        } else {
          total += size([.fullSizePhoto, .photo])
          if asset.mediaSubtypes.contains(.photoLive) {
            total += size([.fullSizePairedVideo, .pairedVideo])
          }
        }
      }
    }
    return total
  }

  static func cloudIds(for localIds: [String]) -> [String: String] {
    guard !localIds.isEmpty else { return [:] }
    var out: [String: String] = [:]
    let map = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: localIds)
    for (k, v) in map { if case .success(let cid) = v { out[k] = cid.stringValue } }
    return out
  }

  /// Regular user albums, including those inside folders (names flattened with " / ").
  static func albums() -> [LocalAlbum] {
    var out: [LocalAlbum] = []
    func walk(_ result: PHFetchResult<PHCollection>, prefix: String) {
      result.enumerateObjects { c, _, _ in
        let title = c.localizedTitle ?? "Untitled"
        let name = prefix.isEmpty ? title : "\(prefix) / \(title)"
        if let album = c as? PHAssetCollection, album.assetCollectionSubtype == .albumRegular {
          let assets = PHAsset.fetchAssets(in: album, options: nil)
          var ids: [String] = []
          assets.enumerateObjects { a, _, _ in ids.append(a.localIdentifier) }
          out.append(LocalAlbum(localId: album.localIdentifier, name: name, assetLocalIds: ids))
        } else if let folder = c as? PHCollectionList {
          walk(PHCollection.fetchCollections(in: folder, options: nil), prefix: name)
        }
      }
    }
    walk(PHCollectionList.fetchTopLevelUserCollections(with: nil), prefix: "")
    return out
  }

  /// Exports the current version (edits applied) of an asset to temp files and hashes them.
  /// Downloads from iCloud if the original is not on the device.
  static func export(
    localId: String,
    onProgress: @escaping @Sendable (_ filename: String, _ fraction: Double) -> Void = { _, _ in }
  )
    async throws -> ExportedAsset
  {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject
    else {
      throw PhotoLibraryError.assetMissing(localId)
    }
    let resources = PHAssetResource.assetResources(for: asset)
    func pick(_ types: [PHAssetResourceType]) -> PHAssetResource? {
      for t in types { if let r = resources.first(where: { $0.type == t }) { return r } }
      return nil
    }
    let primaryRes: PHAssetResource?
    var videoRes: PHAssetResource? = nil
    switch asset.mediaType {
    case .video:
      primaryRes = pick([.fullSizeVideo, .video])
    default:
      primaryRes = pick([.fullSizePhoto, .photo])
      if asset.mediaSubtypes.contains(.photoLive) {
        videoRes = pick([.fullSizePairedVideo, .pairedVideo])
      }
    }
    guard let primaryRes else { throw PhotoLibraryError.noResource(localId) }

    let primary = try await write(primaryRes, onProgress: onProgress)
    var paired: ExportedFile? = nil
    if let videoRes {
      do { paired = try await write(videoRes, onProgress: onProgress) } catch {
        try? FileManager.default.removeItem(at: primary.url)
        throw error
      }
    }
    return ExportedAsset(
      localId: localId, primary: primary, pairedVideo: paired,
      createdAt: asset.creationDate ?? Date(),
      modifiedAt: asset.modificationDate ?? asset.creationDate ?? Date(),
      isFavorite: asset.isFavorite,
      durationMs: asset.mediaType == .video ? Int(asset.duration * 1000) : nil)
  }

  /// Abort a download that shows no progress for this long (iCloud can stall on large originals).
  static var stallTimeout: TimeInterval = 60

  /// Streams the resource to a temp file while hashing it. Cancellable; times out when stalled.
  private static func write(
    _ res: PHAssetResource,
    onProgress: @escaping @Sendable (String, Double) -> Void
  ) async throws -> ExportedFile {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "export", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(UUID().uuidString + "-" + res.originalFilename)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let job = try ExportJob(url: url)
    let name = res.originalFilename

    let opts = PHAssetResourceRequestOptions()
    opts.isNetworkAccessAllowed = true
    opts.progressHandler = { p in
      job.touch()
      onProgress(name, p)
    }

    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          guard job.begin(c) else { return }
          job.requestId = PHAssetResourceManager.default().requestData(
            for: res, options: opts,
            dataReceivedHandler: { data in job.append(data) },
            completionHandler: { error in job.finish(error) })
          job.startWatchdog(timeout: stallTimeout, filename: name)
        }
      } onCancel: {
        job.finish(CancellationError())
      }
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    let digest = job.digest()
    let mime = UTType(res.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
    return ExportedFile(
      url: url, filename: name, mimeType: mime,
      sha1Hex: digest.map { String(format: "%02x", $0) }.joined(),
      sha1Base64: Data(digest).base64EncodedString())
  }

  static func sha1(of url: URL) throws -> Insecure.SHA1.Digest {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hasher = Insecure.SHA1()
    while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize()
  }
}

struct ExportStalledError: LocalizedError {
  let filename: String
  let seconds: Int
  var errorDescription: String? { "\(filename): iCloud download stalled for \(seconds)s — skipped" }
}

/// State for one streaming resource request. PhotoKit calls back on its own queues → guarded by a lock.
private final class ExportJob: @unchecked Sendable {
  private let lock = NSLock()
  private let handle: FileHandle
  private var hasher = Insecure.SHA1()
  private var lastActivity = Date()
  private var done = false
  private var writeError: Error?
  var continuation: CheckedContinuation<Void, Error>?
  var requestId: PHAssetResourceDataRequestID?

  init(url: URL) throws { handle = try FileHandle(forWritingTo: url) }

  /// Returns false (and resumes with cancellation) if the job was already cancelled.
  func begin(_ c: CheckedContinuation<Void, Error>) -> Bool {
    lock.lock()
    if done {
      lock.unlock()
      c.resume(throwing: CancellationError())
      return false
    }
    continuation = c
    lock.unlock()
    return true
  }

  func touch() {
    lock.lock()
    lastActivity = Date()
    lock.unlock()
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !done else { return }
    lastActivity = Date()
    do {
      try handle.write(contentsOf: data)
      hasher.update(data: data)
    } catch { writeError = error }
  }

  func finish(_ error: Error?) {
    lock.lock()
    guard !done else {
      lock.unlock()
      return
    }
    done = true
    let c = continuation
    continuation = nil
    let rid = requestId
    let err = error ?? writeError
    try? handle.close()
    lock.unlock()
    if err != nil, let rid { PHAssetResourceManager.default().cancelDataRequest(rid) }
    if let err { c?.resume(throwing: err) } else { c?.resume() }
  }

  func digest() -> Insecure.SHA1.Digest {
    lock.lock()
    defer { lock.unlock() }
    return hasher.finalize()
  }

  /// (done, seconds since last activity) — synchronous so the lock is never held across an await.
  private func status() -> (Bool, TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    return (done, Date().timeIntervalSince(lastActivity))
  }

  func startWatchdog(timeout: TimeInterval, filename: String) {
    Task.detached { [weak self] in
      while true {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard let self else { return }
        let (finished, idle) = self.status()
        if finished { return }
        if idle > timeout {
          self.finish(ExportStalledError(filename: filename, seconds: Int(idle)))
          return
        }
      }
    }
  }
}
