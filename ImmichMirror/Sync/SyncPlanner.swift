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

    if !plan.removed.isEmpty {
      if local.isEmpty {
        plan.deletionBlockedReason =
          "The photo library appears empty — refusing to trash \(plan.removed.count) photos."
      } else {
        let limit = max(g.alwaysAllowUpTo, Int(Double(stored.count) * g.maxFraction))
        if plan.removed.count > limit {
          plan.deletionBlockedReason =
            "\(plan.removed.count) photos would be trashed (limit \(limit)). Confirm to proceed."
        }
      }
    }
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
      plan.deletionBlockedReason =
        "No albums found locally — refusing to delete \(plan.delete.count) Immich albums."
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

  static func albumMarker(_ localId: String) -> String { "immich-mirror:\(localId)" }
}
