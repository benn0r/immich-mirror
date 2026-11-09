import Foundation

struct DeletionGuard: Equatable {
  /// Block when more than this fraction of mirrored photos would be trashed in one run…
  var maxFraction: Double = 0.05
  /// …unless the absolute number is at most this.
  var alwaysAllowUpTo: Int = 25
}

struct AssetPlan: Equatable {
  var new: [String] = []  // local ids not yet on server
  var changed: [String] = []  // modification date moved → re-hash, maybe re-upload
  var favoriteOnly: [String] = []  // only favorite flag differs
  var removed: [MirrorRecord] = []  // gone from iCloud → trash on server
  var deletionBlockedReason: String? = nil
  /// The block can never be confirmed (empty library: almost certainly a permission or iCloud glitch).
  var deletionBlockedHard = false

  var deletionBlocked: Bool { deletionBlockedReason != nil }
}

struct AlbumPlan: Equatable {
  struct Rename: Equatable {
    var record: AlbumRecord
    var newName: String
  }
  var create: [LocalAlbum] = []
  var rename: [Rename] = []
  var keep: [(local: LocalAlbum, record: AlbumRecord)] = []
  var delete: [AlbumRecord] = []
  var deletionBlockedReason: String? = nil

  static func == (l: AlbumPlan, r: AlbumPlan) -> Bool {
    l.create == r.create && l.rename == r.rename && l.delete == r.delete
      && l.keep.map(\.local) == r.keep.map(\.local) && l.keep.map(\.record) == r.keep.map(\.record)
      && l.deletionBlockedReason == r.deletionBlockedReason
  }
}

struct RecoveryPlan: Equatable {
  struct Adopt: Equatable {
    var record: MirrorRecord
    /// Server ids to bring back from Immich's trash (the photo still exists in iCloud).
    var restore: [String]
    /// Edited since it was uploaded: re-checked like any changed photo.
    var edited: Bool
  }
  struct Orphan: Equatable {
    var immichId: String
    var liveVideoImmichId: String?
  }
  var adopt: [Adopt] = []
  /// This app's server copies whose iCloud photo is gone.
  var orphans: [Orphan] = []
  /// Leftover check skipped because iCloud ids could not be read for enough photos.
  var orphansSkipped = false
}

/// Pure decision logic — no I/O, fully unit-tested.
enum SyncPlanner {
  static func planAssets(
    local: [LocalAsset], stored: [String: MirrorRecord], guard g: DeletionGuard
  ) -> AssetPlan {
    var plan = AssetPlan()
    var seen = Set<String>()
    for a in local {
      seen.insert(a.localId)
      guard let rec = stored[a.localId] else {
        plan.new.append(a.localId)
        continue
      }
      if abs(rec.modifiedAt - a.modifiedAt) > 0.5 {
        plan.changed.append(a.localId)
      } else if rec.isFavorite != a.isFavorite {
        plan.favoriteOnly.append(a.localId)
      }
    }
    plan.removed = stored.values.filter { !seen.contains($0.localId) }.sorted {
      $0.localId < $1.localId
    }

    (plan.deletionBlockedReason, plan.deletionBlockedHard) = deletionBlock(
      removing: plan.removed.count, mirrored: stored.count, localIsEmpty: local.isEmpty, guard: g)
    return plan
  }

  /// Why trashing `removing` of `mirrored` server photos must wait for confirmation, if it must.
  /// `hard`: never confirmable (an empty library is almost certainly a permission or iCloud glitch).
  static func deletionBlock(
    removing: Int, mirrored: Int, localIsEmpty: Bool, guard g: DeletionGuard
  ) -> (reason: String?, hard: Bool) {
    guard removing > 0 else { return (nil, false) }
    if localIsEmpty {
      return (
        String(
          localized: "The photo library appears empty — refusing to trash \(removing) photos."),
        true
      )
    }
    let limit = max(g.alwaysAllowUpTo, Int(Double(mirrored) * g.maxFraction))
    guard removing > limit else { return (nil, false) }
    return (
      String(
        localized: "\(removing) photos would be trashed (limit \(limit)). Confirm to proceed."),
      false
    )
  }

  // MARK: - Rebuild from the server

  /// Links new local photos to copies this app put on the server earlier (found by iCloud id, or by
  /// local id on the same device), and finds server copies whose iCloud photo no longer exists.
  /// Used when the local mapping is missing (app reinstalled, new iPhone) or another device synced.
  ///
  /// - Parameters:
  ///   - new: local photos without a mapping.
  ///   - local: the whole local library.
  ///   - cloudIds: localId → iCloud id for the whole library (lookups that failed are missing).
  ///   - mapped: server asset ids already in the local mapping (photos and live-photo videos).
  static func planRecovery(
    new: [LocalAsset], local: [LocalAsset], cloudIds: [String: String], index: ServerIndex,
    mapped: Set<String>
  ) -> RecoveryPlan {
    var plan = RecoveryPlan()
    let videoIds = Set(index.assets.values.compactMap(\.livePhotoVideoId))
    // Candidates: this app's photos (not the hidden video half of a live photo), never external ones.
    var byCloud: [String: [String]] = [:]
    var byLocal: [String: [String]] = [:]
    for (id, meta) in index.mirror {
      guard let a = index.assets[id], !a.isExternal, !a.isHidden, !videoIds.contains(id),
        !mapped.contains(id)
      else { continue }
      if let c = meta.cloudId { byCloud[c, default: []].append(id) }
      byLocal[meta.localId, default: []].append(id)
    }
    /// Prefers a copy that is not in the trash, then the most recently uploaded version.
    func best(_ ids: [String], claimed: Set<String>) -> String? {
      ids.filter { !claimed.contains($0) }.max { l, r in
        let la = index.assets[l]!
        let ra = index.assets[r]!
        if la.isTrashed != ra.isTrashed { return la.isTrashed }
        return (index.mirror[l]?.modifiedAt ?? 0, l) < (index.mirror[r]?.modifiedAt ?? 0, r)
      }
    }

    var claimed = Set<String>()
    for photo in new {
      let cloudId = cloudIds[photo.localId]
      let candidates = cloudId.flatMap { byCloud[$0] } ?? byLocal[photo.localId] ?? []
      guard let id = best(candidates, claimed: claimed), let asset = index.assets[id] else {
        continue
      }
      claimed.insert(id)
      let video = asset.livePhotoVideoId.flatMap { index.assets[$0] }
      video.map { claimed.insert($0.id) }
      // An upload that records its modification date shows whether the photo was edited since.
      let uploadedAt = index.mirror[id]?.modifiedAt
      let edited = uploadedAt.map { abs($0 - photo.modifiedAt) > 0.5 } ?? false
      plan.adopt.append(
        .init(
          record: MirrorRecord(
            localId: photo.localId, cloudId: cloudId, immichId: id,
            liveVideoImmichId: video?.id, checksum: asset.checksum,
            modifiedAt: edited ? uploadedAt! : photo.modifiedAt, isFavorite: asset.isFavorite),
          restore: ([asset] + (video.map { [$0] } ?? [])).filter(\.isTrashed).map(\.id),
          edited: edited))
    }

    // Leftovers: needs reliable iCloud ids, otherwise a failed lookup would look like a deletion.
    let missing = local.count - cloudIds.count
    if local.isEmpty || Double(missing) > Double(local.count) * 0.01 {
      plan.orphansSkipped = !index.mirror.isEmpty
      return plan
    }
    let localCloud = Set(cloudIds.values)
    let localIds = Set(local.map(\.localId))
    for (id, meta) in index.mirror {
      guard let a = index.assets[id], !a.isExternal, !a.isTrashed, !a.isHidden,
        !videoIds.contains(id),
        !mapped.contains(id), !claimed.contains(id), let c = meta.cloudId,
        !localCloud.contains(c), !localIds.contains(meta.localId)
      else { continue }
      let video = a.livePhotoVideoId.flatMap { index.assets[$0] }.flatMap {
        $0.isTrashed ? nil : $0
      }
      plan.orphans.append(.init(immichId: id, liveVideoImmichId: video?.id))
    }
    plan.orphans.sort { $0.immichId < $1.immichId }
    return plan
  }

  static func planAlbums(local: [LocalAlbum], stored: [String: AlbumRecord]) -> AlbumPlan {
    var plan = AlbumPlan()
    var seen = Set<String>()
    for a in local {
      seen.insert(a.localId)
      if let rec = stored[a.localId] {
        if rec.name != a.name { plan.rename.append(.init(record: rec, newName: a.name)) }
        plan.keep.append((a, rec))
      } else {
        plan.create.append(a)
      }
    }
    plan.delete = stored.values.filter { !seen.contains($0.localId) }.sorted {
      $0.localId < $1.localId
    }
    if local.isEmpty && !plan.delete.isEmpty {
      plan.deletionBlockedReason = String(
        localized:
          "No albums found locally — refusing to delete \(plan.delete.count) Immich albums.")
    }
    return plan
  }

  /// Immich asset ids an album should contain, given the local membership and the mirror table.
  static func desiredMembers(_ album: LocalAlbum, mapping: [String: MirrorRecord]) -> Set<String> {
    Set(album.assetLocalIds.compactMap { mapping[$0]?.immichId })
  }

  /// Evenly spaced sample across the whole library (old and new photos), for dry-run estimates.
  static func spreadSample<T>(_ items: [T], count: Int) -> [T] {
    guard items.count > count, count > 0 else { return items }
    let step = Double(items.count) / Double(count)
    return (0..<count).map { items[Int(Double($0) * step)] }
  }

  /// Description of a mirrored album on the server. With the iCloud id, another device (or this
  /// one after a reinstall) finds the album again although its local id differs.
  static func albumMarker(_ localId: String, cloudId: String? = nil) -> String {
    "immich-mirror:\(localId)" + (cloudId.map { " cloud:\($0)" } ?? "")
  }

  /// Whether a server album's description marks it as the mirror of this local album.
  static func albumMatches(description: String, localId: String, cloudId: String?) -> Bool {
    let parts = description.split(separator: " ").map(String.init)
    if parts.first == "immich-mirror:\(localId)" { return true }
    guard let cloudId else { return false }
    return parts.first?.hasPrefix("immich-mirror:") == true && parts.contains("cloud:\(cloudId)")
  }
}
