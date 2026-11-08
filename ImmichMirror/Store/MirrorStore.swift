import Foundation

/// One iCloud photo that is mirrored on the server.
struct MirrorRecord: Equatable {
  var localId: String
  var cloudId: String?
  var immichId: String
  var liveVideoImmichId: String?
  var checksum: String  // base64 SHA-1 of the uploaded file (matches Immich's `checksum`)
  var modifiedAt: Double  // PHAsset.modificationDate at time of last sync
  var isFavorite: Bool
}

/// One iCloud album mirrored as an Immich album.
struct AlbumRecord: Equatable {
  var localId: String
  var immichId: String
  var name: String
}

/// Local source of truth for "what did we put on the server". Owned by SyncEngine.
final class MirrorStore {
  private let db: SQLite

  /// Keyed by user so switching accounts never mixes mappings.
  init(userId: String) throws {
    let dir = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let safe = userId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    db = try SQLite(path: dir.appendingPathComponent("mirror-\(safe).sqlite").path)
    try migrate()
  }

  init(path: String) throws {
    db = try SQLite(path: path)
    try migrate()
  }

  private func migrate() throws {
    try db.exec(
      """
      CREATE TABLE IF NOT EXISTS assets(
        local_id TEXT PRIMARY KEY,
        cloud_id TEXT,
        immich_id TEXT NOT NULL,
        live_video_immich_id TEXT,
        checksum TEXT NOT NULL,
        modified_at REAL NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS assets_immich ON assets(immich_id);
      CREATE TABLE IF NOT EXISTS albums(
        local_id TEXT PRIMARY KEY,
        immich_id TEXT NOT NULL,
        name TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT);
      """)
  }

  // MARK: assets

  func allAssets() throws -> [String: MirrorRecord] {
    var out: [String: MirrorRecord] = [:]
    try db.query(
      "SELECT local_id, cloud_id, immich_id, live_video_immich_id, checksum, modified_at, is_favorite FROM assets"
    ) { r in
      let rec = MirrorRecord(
        localId: r.text(0)!, cloudId: r.text(1), immichId: r.text(2)!, liveVideoImmichId: r.text(3),
        checksum: r.text(4)!, modifiedAt: r.real(5), isFavorite: r.int(6) != 0)
      out[rec.localId] = rec
    }
    return out
  }

  func upsert(_ r: MirrorRecord) throws {
    try db.run(
      """
      INSERT INTO assets(local_id, cloud_id, immich_id, live_video_immich_id, checksum, modified_at, is_favorite)
      VALUES(?,?,?,?,?,?,?)
      ON CONFLICT(local_id) DO UPDATE SET cloud_id=excluded.cloud_id, immich_id=excluded.immich_id,
        live_video_immich_id=excluded.live_video_immich_id, checksum=excluded.checksum,
        modified_at=excluded.modified_at, is_favorite=excluded.is_favorite
      """,
      [
        .text(r.localId), r.cloudId.sql, .text(r.immichId), r.liveVideoImmichId.sql,
        .text(r.checksum),
        .real(r.modifiedAt), .int(r.isFavorite ? 1 : 0),
      ])
  }

  func deleteAsset(localId: String) throws {
    try db.run("DELETE FROM assets WHERE local_id = ?", [.text(localId)])
  }

  /// Most recently added/updated mappings first.
  func recentAssets(limit: Int) throws -> [MirrorRecord] {
    var out: [MirrorRecord] = []
    try db.query(
      "SELECT local_id, cloud_id, immich_id, live_video_immich_id, checksum, modified_at, is_favorite FROM assets ORDER BY rowid DESC LIMIT ?",
      [.int(Int64(limit))]
    ) { r in
      out.append(
        MirrorRecord(
          localId: r.text(0)!, cloudId: r.text(1), immichId: r.text(2)!,
          liveVideoImmichId: r.text(3),
          checksum: r.text(4)!, modifiedAt: r.real(5), isFavorite: r.int(6) != 0))
    }
    return out
  }

  func assetCount() throws -> Int { try db.scalarInt("SELECT COUNT(*) FROM assets") }

  // MARK: albums

  func allAlbums() throws -> [String: AlbumRecord] {
    var out: [String: AlbumRecord] = [:]
    try db.query("SELECT local_id, immich_id, name FROM albums") { r in
      out[r.text(0)!] = AlbumRecord(localId: r.text(0)!, immichId: r.text(1)!, name: r.text(2)!)
    }
    return out
  }

  func upsert(_ a: AlbumRecord) throws {
    try db.run(
      """
      INSERT INTO albums(local_id, immich_id, name) VALUES(?,?,?)
      ON CONFLICT(local_id) DO UPDATE SET immich_id=excluded.immich_id, name=excluded.name
      """, [.text(a.localId), .text(a.immichId), .text(a.name)])
  }

  func deleteAlbum(localId: String) throws {
    try db.run("DELETE FROM albums WHERE local_id = ?", [.text(localId)])
  }

  // MARK: kv

  func get(_ key: String) throws -> String? {
    var v: String?
    try db.query("SELECT value FROM kv WHERE key = ?", [.text(key)]) { v = $0.text(0) }
    return v
  }

  func set(_ key: String, _ value: String?) throws {
    try db.run(
      "INSERT INTO kv(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      [.text(key), value.sql])
  }

  func reset() throws {
    try db.exec("DELETE FROM assets; DELETE FROM albums; DELETE FROM kv;")
  }
}
