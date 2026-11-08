import Foundation

struct SyncSettings: Equatable {
  var dryRun = true
  var syncAlbums = true
  var deletionGuard = DeletionGuard()
  /// In dry-run mode, only this many new photos are exported/hashed to estimate adopt-vs-upload.
  var dryRunSample = 200
  /// Max new photos uploaded per run (0 = no limit). For a careful first test run.
  var uploadLimit = 0

  private static let d = UserDefaults.standard
  static func load() -> SyncSettings {
    var s = SyncSettings()
    if d.object(forKey: "dryRun") != nil { s.dryRun = d.bool(forKey: "dryRun") }
    if d.object(forKey: "syncAlbums") != nil { s.syncAlbums = d.bool(forKey: "syncAlbums") }
    if d.object(forKey: "guardFraction") != nil {
      s.deletionGuard.maxFraction = d.double(forKey: "guardFraction")
    }
    if d.object(forKey: "guardMin") != nil {
      s.deletionGuard.alwaysAllowUpTo = d.integer(forKey: "guardMin")
    }
    s.uploadLimit = d.integer(forKey: "uploadLimit")
    return s
  }
  func save() {
    Self.d.set(dryRun, forKey: "dryRun")
    Self.d.set(syncAlbums, forKey: "syncAlbums")
    Self.d.set(deletionGuard.maxFraction, forKey: "guardFraction")
    Self.d.set(deletionGuard.alwaysAllowUpTo, forKey: "guardMin")
    Self.d.set(uploadLimit, forKey: "uploadLimit")
  }
}

struct SyncProgress: Equatable {
  var phase: String
  var done: Int = 0
  var total: Int = 0
  var detail: String? = nil  // e.g. "IMG_1234.HEIC · downloading 42%"
  /// Download/upload activity within the current item: counts as forward progress for iOS.
  var tick = false
}

struct SyncReport: Equatable {
  var dryRun: Bool
  var startedAt = Date()
  var finishedAt: Date?
  var localCount = 0
  var mirroredBefore = 0
  var mirroredAfter = 0

  var newFound = 0
  var changedFound = 0
  var uploaded = 0
  var adopted = 0  // already on server (same checksum) → linked, no upload
  var restored = 0  // was in Immich trash but exists in iCloud → restored
  var reuploaded = 0  // edited in iCloud → new version uploaded, old one trashed
  var favoritesUpdated = 0
  var trashed = 0
  var deletionBlockedReason: String?
  var deletionBlockedHard = false
  var pendingDeletions = 0

  var sampled = 0  // dry run: how many new photos were hashed for the estimate
  var sampleAdopt = 0
  var sampleUpload = 0
  /// Dry run: size of all new photos (originals as they would be uploaded).
  var estimatedUploadBytes: Int64 = 0

  var albumsCreated = 0
  var albumsRenamed = 0
  var albumsDeleted = 0
  var albumAssetsAdded = 0
  var albumAssetsRemoved = 0

  var failures: [String] = []
  var diagnostics: [String] = []
  struct Placed: Equatable {
    let filename: String
    let immichId: String
    let how: String
  }
  /// Uploaded/adopted this run (capped), for "show in Immich" links.
  var placed: [Placed] = []
  var cancelled = false
}

/// Runs one mirror pass: iCloud library → Immich. iCloud is the source of truth.
///
/// Safety rules:
///  * Only server assets/albums recorded in the local MirrorStore are ever modified or trashed.
///  * Deletion is always soft (Immich trash); large deletions need explicit confirmation.
///  * Dry run performs no writes on the server or in the local store.
actor SyncEngine {
  private let client: ImmichClient
  private let store: MirrorStore
  private let settings: SyncSettings
  private let onProgress: @Sendable (SyncProgress) -> Void
  private let onLog: @Sendable (String) -> Void

  init(
    client: ImmichClient, store: MirrorStore, settings: SyncSettings,
    onProgress: @escaping @Sendable (SyncProgress) -> Void,
    onLog: @escaping @Sendable (String) -> Void
  ) {
    self.client = client
    self.store = store
    self.settings = settings
    self.onProgress = onProgress
    self.onLog = onLog
  }

  private var dry: Bool { settings.dryRun }

  func run(confirmMassDeletion: Bool) async throws -> SyncReport {
    var report = SyncReport(dryRun: dry)
    Self.removeLeftoverTempFiles()
    try PhotoLibrary.requireFullAccess()
    guard try await client.validateToken() else { throw ImmichError.unauthorized }

    onProgress(.init(phase: String(localized: "Scanning library")))
    let local = PhotoLibrary.localAssets()
    let localById = Dictionary(local.map { ($0.localId, $0) }, uniquingKeysWith: { a, _ in a })
    var stored = try store.allAssets()
    report.localCount = local.count
    report.mirroredBefore = stored.count

    let plan = SyncPlanner.planAssets(local: local, stored: stored, guard: settings.deletionGuard)
    report.newFound = plan.new.count
    report.changedFound = plan.changed.count
    onLog(
      "Library: \(local.count) photos, mirrored: \(stored.count), new: \(plan.new.count), changed: \(plan.changed.count), removed: \(plan.removed.count)\(dry ? " [dry run]" : "")"
    )

    if dry, !plan.new.isEmpty {
      onProgress(.init(phase: String(localized: "Measuring library size")))
      report.estimatedUploadBytes = PhotoLibrary.estimatedSize(of: plan.new)
      onLog(
        "[dry run] new photos total ≈ \(ByteCountFormatter.string(fromByteCount: report.estimatedUploadBytes, countStyle: .file))"
      )
    }

    // 1. Deletions first (cheap, and keeps the server from holding stale items during a long upload).
    try await applyDeletions(plan, confirmed: confirmMassDeletion, report: &report)
    if Task.isCancelled {
      report.cancelled = true
      return finish(report)
    }

    // 2. Favorite-only changes.
    try await applyFavorites(
      plan.favoriteOnly, localById: localById, stored: &stored, report: &report)

    // 3. Changed (edited) photos.
    try await applyChanged(plan.changed, stored: &stored, report: &report)
    if Task.isCancelled {
      report.cancelled = true
      return finish(report)
    }

    // 4. New photos (adopt existing server copies by checksum, otherwise upload).
    try await applyNew(plan.new, stored: &stored, report: &report)
    if Task.isCancelled {
      report.cancelled = true
      return finish(report)
    }

    // 5. Albums.
    if settings.syncAlbums {
      try await syncAlbums(mapping: dry ? stored : try store.allAssets(), report: &report)
    }

    report.mirroredAfter = dry ? stored.count : try store.assetCount()
    return finish(report)
  }

  /// A crash or kill mid-run can leave exported originals / multipart bodies in tmp (videos can be GBs).
  static func removeLeftoverTempFiles() {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
    try? fm.removeItem(at: tmp.appendingPathComponent("export", isDirectory: true))
    for f in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
    where f.lastPathComponent.hasPrefix("upload-") && f.pathExtension == "body" {
      try? fm.removeItem(at: f)
    }
  }

  private func finish(_ r: SyncReport) -> SyncReport {
    var r = r
    r.finishedAt = Date()
    if !dry { try? store.set("lastSync", ISO8601.string(Date())) }
    onProgress(
      .init(phase: r.cancelled ? String(localized: "Cancelled") : String(localized: "Done")))
    return r
  }

  // MARK: - Deletions

  private func applyDeletions(_ plan: AssetPlan, confirmed: Bool, report: inout SyncReport)
    async throws
  {
    guard !plan.removed.isEmpty else { return }
    report.pendingDeletions = plan.removed.count
    if let reason = plan.deletionBlockedReason, !(confirmed && !reasonIsHardBlock(plan)) {
      report.deletionBlockedReason = reason
      report.deletionBlockedHard = plan.deletionBlockedHard
      onLog("⚠️ Deletion blocked: \(reason)")
      return
    }
    if dry {
      onLog("[dry run] would move \(plan.removed.count) photos to Immich trash")
      return
    }
    onProgress(
      .init(
        phase: String(localized: "Moving deleted photos to trash"), done: 0,
        total: plan.removed.count))
    var done = 0
    for chunk in plan.removed.chunked(200) {
      let ids = chunk.flatMap { [$0.immichId] + ($0.liveVideoImmichId.map { [$0] } ?? []) }
      try await client.trash(ids: ids)
      for r in chunk { try store.deleteAsset(localId: r.localId) }
      done += chunk.count
      report.trashed += chunk.count
      onProgress(
        .init(
          phase: String(localized: "Moving deleted photos to trash"), done: done,
          total: plan.removed.count))
    }
    onLog("Trashed \(report.trashed) photos deleted from iCloud")
  }

  /// An empty library is never confirmable — that is almost certainly a permission or iCloud glitch.
  private func reasonIsHardBlock(_ plan: AssetPlan) -> Bool {
    plan.deletionBlockedHard
  }

  // MARK: - Favorites

  private func applyFavorites(
    _ ids: [String], localById: [String: LocalAsset],
    stored: inout [String: MirrorRecord], report: inout SyncReport
  ) async throws {
    guard !ids.isEmpty else { return }
    if dry {
      onLog("[dry run] would update favorite flag on \(ids.count) photos")
      return
    }
    let groups = Dictionary(grouping: ids) { localById[$0]?.isFavorite ?? false }
    for (fav, locals) in groups {
      let immichIds = locals.compactMap { stored[$0]?.immichId }
      try await client.setFavorite(ids: immichIds, fav)
      for l in locals {
        if var r = stored[l] {
          r.isFavorite = fav
          stored[l] = r
          try store.upsert(r)
        }
      }
      report.favoritesUpdated += locals.count
    }
  }

  // MARK: - Changed

  private func applyChanged(
    _ ids: [String], stored: inout [String: MirrorRecord], report: inout SyncReport
  ) async throws {
    guard !ids.isEmpty else { return }
    if dry {
      onLog("[dry run] \(ids.count) photos changed since last sync (would re-check)")
      return
    }
    for (i, localId) in ids.enumerated() {
      if Task.isCancelled { return }
      onProgress(
        .init(phase: String(localized: "Checking edited photos"), done: i, total: ids.count))
      guard var rec = stored[localId] else { continue }
      do {
        let progress = onProgress
        let n = ids.count
        let exp = try await PhotoLibrary.export(localId: localId) { name, f in
          progress(
            .init(
              phase: String(localized: "Checking edited photos"), done: i, total: n,
              detail: String(localized: "\(name) · downloading from iCloud \(Int(f * 100))%"),
              tick: true))
        }
        defer { exp.cleanup() }
        if exp.primary.sha1Base64 == rec.checksum {
          // Only metadata changed (e.g. favorite) — no new file.
          if rec.isFavorite != exp.isFavorite {
            try await client.setFavorite(ids: [rec.immichId], exp.isFavorite)
            report.favoritesUpdated += 1
          }
          rec.modifiedAt = exp.modifiedAt.timeIntervalSince1970
          rec.isFavorite = exp.isFavorite
        } else {
          let cloudId = PhotoLibrary.cloudIds(for: [localId])[localId] ?? rec.cloudId
          let (newId, videoId, _) = try await place(exp, cloudId: cloudId)
          let old = [rec.immichId] + (rec.liveVideoImmichId.map { [$0] } ?? [])
          let stale = old.filter { $0 != newId && $0 != videoId }
          try await client.trash(ids: stale)
          rec = MirrorRecord(
            localId: localId, cloudId: cloudId, immichId: newId, liveVideoImmichId: videoId,
            checksum: exp.primary.sha1Base64, modifiedAt: exp.modifiedAt.timeIntervalSince1970,
            isFavorite: exp.isFavorite)
          report.reuploaded += 1
        }
        stored[localId] = rec
        try store.upsert(rec)
      } catch let e as ImmichError where isFatal(e) {
        throw e
      } catch {
        report.failures.append("\(localId): \(error.localizedDescription)")
      }
    }
  }

  // MARK: - New

  private func applyNew(
    _ ids: [String], stored: inout [String: MirrorRecord], report: inout SyncReport
  ) async throws {
    guard !ids.isEmpty else { return }
    let work =
      dry
      ? SyncPlanner.spreadSample(ids, count: settings.dryRunSample)
      : (settings.uploadLimit > 0 ? Array(ids.prefix(settings.uploadLimit)) : ids)
    if !dry, work.count < ids.count {
      onLog("Upload limit: \(work.count) of \(ids.count) new photos this run")
    }
    let phase =
      dry
      ? String(localized: "Estimating (sample of \(work.count))")
      : String(localized: "Uploading new photos")
    var done = 0
    for batch in work.chunked(24) {
      if Task.isCancelled { return }
      let cloud = PhotoLibrary.cloudIds(for: batch)
      let (exported, failed) = await exportAll(
        batch, phase: phase, doneBefore: done, total: work.count)
      report.failures += failed
      defer { for e in exported { e.cleanup() } }
      if Task.isCancelled { return }
      guard !exported.isEmpty else {
        done += batch.count
        onProgress(.init(phase: phase, done: done, total: work.count))
        continue
      }

      let check = try await client.bulkUploadCheck(
        exported.map { .init(id: $0.localId, checksum: $0.primary.sha1Hex) })
      let byId = Dictionary(check.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

      if dry {
        for e in exported {
          report.sampled += 1
          if byId[e.localId]?.reason == "duplicate" {
            report.sampleAdopt += 1
          } else {
            report.sampleUpload += 1
            if report.diagnostics.count < 15 { report.diagnostics.append(await diagnose(e)) }
          }
        }
        done += batch.count
        onProgress(.init(phase: phase, done: done, total: work.count))
        continue
      }

      var metadata: [MetadataBulkUpsertItem] = []
      for e in exported {
        if Task.isCancelled { break }
        let cloudId = cloud[e.localId]
        do {
          let res = byId[e.localId]
          let immichId: String
          var videoId: String? = nil
          if res?.action == "reject", res?.reason == "duplicate", let existing = res?.assetId {
            // Already on the server → adopt it, but never an external-library asset (e.g. Lightroom share).
            try await requireInternal(existing, filename: e.primary.filename)
            if res?.isTrashed == true {
              try await client.restoreFromTrash(ids: [existing])
              report.restored += 1
            }
            immichId = existing
            metadata.append(
              .init(
                assetId: existing, key: ImmichClient.metadataKey,
                value: .init(localId: e.localId, cloudId: cloudId)))
            report.adopted += 1
            if report.placed.count < 500 {
              report.placed.append(
                .init(
                  filename: e.primary.filename, immichId: existing,
                  how: String(localized: "adopted")))
            }
          } else if res?.action == "reject" {
            report.failures.append("\(e.primary.filename): rejected (\(res?.reason ?? "unknown"))")
            continue
          } else {
            let placed = try await place(e, cloudId: cloudId)
            immichId = placed.id
            videoId = placed.videoId
            report.uploaded += 1
            if report.placed.count < 500 {
              report.placed.append(
                .init(
                  filename: e.primary.filename, immichId: placed.id,
                  how: e.pairedVideo != nil
                    ? String(localized: "live photo") : String(localized: "uploaded")))
            }
          }
          let rec = MirrorRecord(
            localId: e.localId, cloudId: cloudId, immichId: immichId, liveVideoImmichId: videoId,
            checksum: e.primary.sha1Base64, modifiedAt: e.modifiedAt.timeIntervalSince1970,
            isFavorite: e.isFavorite)
          stored[e.localId] = rec
          try store.upsert(rec)
        } catch let err as ImmichError where isFatal(err) {
          throw err
        } catch {
          report.failures.append("\(e.primary.filename): \(error.localizedDescription)")
        }
      }
      try await client.upsertMetadata(metadata)
      done += batch.count
      onProgress(.init(phase: phase, done: done, total: work.count))
    }
    if dry {
      onLog(
        "[dry run] sample of \(report.sampled): \(report.sampleAdopt) already on server, \(report.sampleUpload) would upload"
      )
    } else {
      onLog(
        "Uploaded \(report.uploaded), adopted \(report.adopted) existing, restored \(report.restored) from trash"
      )
    }
  }

  /// Looks for a server copy of an unmatched photo by filename, then by capture time, and describes it.
  private func diagnose(_ e: ExportedAsset) async -> String {
    let name = e.primary.filename
    let base = (name as NSString).deletingPathExtension
    let local = "\(name) [\(e.primary.mimeType), sha \(e.primary.sha1Base64.prefix(8))]"
    do {
      var hits = try await client.searchFirst(.init(originalFileName: .init(startsWith: base)))
      var how = "name"
      if hits.isEmpty {
        let t = e.createdAt
        hits = try await client.searchFirst(
          .init(
            takenAt: .init(
              gte: ISO8601.string(t.addingTimeInterval(-2)),
              lte: ISO8601.string(t.addingTimeInterval(2)))))
        how = "time"
      }
      guard !hits.isEmpty else { return "\(local) → not on server" }
      let desc = hits.prefix(2).map { h in
        "\(h.originalFileName ?? "?") [\(h.originalMimeType ?? "?"), sha \(h.checksum.prefix(8))\(h.libraryId != nil ? ", external library" : "")] \(h.originalPath ?? "")"
      }.joined(separator: " | ")
      return "\(local) → by \(how): \(desc)"
    } catch {
      return "\(local) → lookup failed: \(error.localizedDescription)"
    }
  }

  /// Exports (downloads from iCloud if needed + hashes) up to 4 assets concurrently.
  private func exportAll(_ ids: [String], phase: String, doneBefore: Int, total: Int) async -> (
    [ExportedAsset], [String]
  ) {
    let progress = onProgress
    var exported: [ExportedAsset] = []
    var failed: [String] = []
    var finished = 0
    await withTaskGroup(of: (String, Result<ExportedAsset, Error>).self) { group in
      var it = ids.makeIterator()
      func add(_ id: String) {
        group.addTask {
          do {
            let e = try await PhotoLibrary.export(localId: id) { name, fraction in
              progress(
                .init(
                  phase: phase, done: doneBefore, total: total,
                  detail: String(
                    localized: "\(name) · downloading from iCloud \(Int(fraction * 100))%"),
                  tick: true))
            }
            return (id, .success(e))
          } catch { return (id, .failure(error)) }
        }
      }
      for _ in 0..<4 { if let id = it.next() { add(id) } }
      for await (id, result) in group {
        finished += 1
        switch result {
        case .success(let e):
          exported.append(e)
          progress(
            .init(
              phase: phase, done: doneBefore + finished, total: total, detail: e.primary.filename))
        case .failure(let err):
          if !(err is CancellationError) { failed.append("\(id): \(err.localizedDescription)") }
          progress(.init(phase: phase, done: doneBefore + finished, total: total, detail: nil))
        }
        if !Task.isCancelled, let next = it.next() { add(next) }
      }
    }
    return (exported, failed)
  }

  /// Uploads an exported asset (live photo: video first, then still linked to it).
  private func place(_ e: ExportedAsset, cloudId: String?) async throws -> (
    id: String, videoId: String?, created: Bool
  ) {
    let meta = MirrorMetadata(localId: e.localId, cloudId: cloudId)
    let progress = onProgress
    func uploading(_ name: String) -> @Sendable (Double) -> Void {
      { f in
        progress(
          .init(
            phase: "", detail: String(localized: "\(name) · uploading \(Int(f * 100))%"), tick: true
          ))
      }
    }
    var videoId: String? = nil
    if let v = e.pairedVideo {
      let r = try await client.upload(
        .init(
          fileURL: v.url, filename: v.filename, mimeType: v.mimeType, checksumHex: v.sha1Hex,
          createdAt: e.createdAt, modifiedAt: e.modifiedAt, isFavorite: false,
          durationMs: nil, livePhotoVideoId: nil, visibility: "hidden", metadata: meta),
        onProgress: uploading(v.filename))
      videoId = r.id
    }
    let r = try await client.upload(
      .init(
        fileURL: e.primary.url, filename: e.primary.filename, mimeType: e.primary.mimeType,
        checksumHex: e.primary.sha1Hex, createdAt: e.createdAt, modifiedAt: e.modifiedAt,
        isFavorite: e.isFavorite, durationMs: e.durationMs, livePhotoVideoId: videoId,
        visibility: nil, metadata: meta), onProgress: uploading(e.primary.filename))
    if r.status == "duplicate" {
      try await requireInternal(r.id, filename: e.primary.filename)
      try await client.upsertMetadata([
        .init(assetId: r.id, key: ImmichClient.metadataKey, value: meta)
      ])
    }
    return (r.id, videoId, r.status == "created")
  }

  struct ExternalLibraryConflict: LocalizedError {
    let filename: String
    var errorDescription: String? {
      String(
        localized:
          "\(filename): identical file exists in an external library — left untouched, not mirrored"
      )
    }
  }

  /// External-library assets belong to someone else's folder (PhotoSync, Lightroom…) — never manage them.
  private func requireInternal(_ id: String, filename: String) async throws {
    if try await client.assetInfo(id: id).libraryId != nil {
      throw ExternalLibraryConflict(filename: filename)
    }
  }

  private func isFatal(_ e: ImmichError) -> Bool {
    if case .unauthorized = e { return true }
    return false
  }

  // MARK: - Albums

  private func syncAlbums(mapping: [String: MirrorRecord], report: inout SyncReport) async throws {
    onProgress(.init(phase: String(localized: "Syncing albums")))
    let local = PhotoLibrary.albums()
    var stored = try store.allAlbums()

    // Recover lost mappings via the description marker on server albums.
    let server = try await client.albums()
    let serverIds = Set(server.map(\.id))
    for a in local where stored[a.localId] == nil {
      if let s = server.first(where: { $0.description == SyncPlanner.albumMarker(a.localId) }) {
        stored[a.localId] = AlbumRecord(localId: a.localId, immichId: s.id, name: s.albumName)
        if !dry { try store.upsert(stored[a.localId]!) }
      }
    }
    // Mapped album deleted on the server by hand → recreate it.
    for (k, rec) in stored where !serverIds.contains(rec.immichId) {
      stored[k] = nil
      if !dry { try store.deleteAlbum(localId: k) }
    }

    let plan = SyncPlanner.planAlbums(local: local, stored: stored)
    if dry {
      onLog(
        "[dry run] albums: create \(plan.create.count), rename \(plan.rename.count), delete \(plan.delete.count), check \(plan.keep.count)"
      )
      report.albumsCreated = plan.create.count
      report.albumsRenamed = plan.rename.count
      report.albumsDeleted = plan.deletionBlockedReason == nil ? plan.delete.count : 0
      return
    }

    let total = plan.create.count + plan.keep.count
    var done = 0
    for a in plan.create {
      if Task.isCancelled { return }
      let members = Array(SyncPlanner.desiredMembers(a, mapping: mapping))
      let created = try await client.createAlbum(
        name: a.name, description: SyncPlanner.albumMarker(a.localId),
        assetIds: Array(members.prefix(500)))
      if members.count > 500 {
        try await client.addToAlbum(id: created.id, assetIds: Array(members.dropFirst(500)))
      }
      try store.upsert(AlbumRecord(localId: a.localId, immichId: created.id, name: a.name))
      report.albumsCreated += 1
      report.albumAssetsAdded += members.count
      done += 1
      onProgress(.init(phase: String(localized: "Syncing albums"), done: done, total: total))
    }
    for r in plan.rename {
      try await client.renameAlbum(id: r.record.immichId, name: r.newName)
      var rec = r.record
      rec.name = r.newName
      try store.upsert(rec)
      report.albumsRenamed += 1
    }
    for (a, rec) in plan.keep {
      if Task.isCancelled { return }
      let want = SyncPlanner.desiredMembers(a, mapping: mapping)
      let have = try await client.albumAssetIds(id: rec.immichId)
      let add = Array(want.subtracting(have))
      let remove = Array(have.subtracting(want))
      if !add.isEmpty { try await client.addToAlbum(id: rec.immichId, assetIds: add) }
      if !remove.isEmpty { try await client.removeFromAlbum(id: rec.immichId, assetIds: remove) }
      report.albumAssetsAdded += add.count
      report.albumAssetsRemoved += remove.count
      done += 1
      onProgress(.init(phase: String(localized: "Syncing albums"), done: done, total: total))
    }
    if let reason = plan.deletionBlockedReason {
      onLog("⚠️ \(reason)")
    } else {
      for rec in plan.delete {
        try await client.deleteAlbum(id: rec.immichId)  // photos stay; only the album goes
        try store.deleteAlbum(localId: rec.localId)
        report.albumsDeleted += 1
      }
    }
    onLog(
      "Albums: +\(report.albumsCreated) created, \(report.albumsRenamed) renamed, \(report.albumsDeleted) deleted, \(report.albumAssetsAdded) added / \(report.albumAssetsRemoved) removed"
    )
  }
}
