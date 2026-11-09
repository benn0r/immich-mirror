import Foundation

// Minimal DTOs for Immich v3.3.x. Field names match Docs/immich-openapi-3.3.6.json.

struct LoginRequest: Encodable {
  let email: String
  let password: String
}

struct LoginResponse: Decodable {
  let accessToken: String
  let userId: String
  let userEmail: String
  let name: String
}

struct ValidateTokenResponse: Decodable { let authStatus: Bool }

struct ServerVersion: Decodable {
  let major: Int, minor: Int, patch: Int
  var string: String { "\(major).\(minor).\(patch)" }
}

struct UserMe: Decodable {
  let id: String
  let name: String
  let email: String
}

struct BulkUploadCheckItem: Encodable {
  let id: String
  let checksum: String
}
struct BulkUploadCheckRequest: Encodable { let assets: [BulkUploadCheckItem] }
struct BulkUploadCheckResult: Decodable {
  let id: String
  let action: String  // "accept" | "reject"
  let reason: String?  // "duplicate" | "unsupported-format"
  let assetId: String?
  let isTrashed: Bool?
}
struct BulkUploadCheckResponse: Decodable { let results: [BulkUploadCheckResult] }

struct AssetInfo: Decodable {
  let id: String
  let libraryId: String?
  let isTrashed: Bool
}

struct UploadResponse: Decodable {
  let id: String
  let status: String
}  // "created" | "duplicate"

/// Value stored under metadata key `immich-mirror` on every asset this app manages.
/// (Key kept from the app's earlier name so existing server data stays linked.)
struct MirrorMetadata: Codable, Equatable {
  var localId: String
  /// PHCloudIdentifier: the same on every device of the iCloud account (local ids are per device).
  var cloudId: String?
  /// PHAsset.modificationDate (seconds since 1970) of the uploaded version, so a rebuild from the
  /// server can tell photos edited in the meantime. Missing on uploads before version 1.1.
  var modifiedAt: Double?
}

/// One of the user's own assets on the server, as the sync stream reports it.
struct ServerAsset: Equatable {
  let id: String
  let checksum: String  // base64 SHA-1, same format as MirrorRecord.checksum
  let isFavorite: Bool
  let isTrashed: Bool
  let isExternal: Bool  // in an external library: never managed by this app
  let livePhotoVideoId: String?
  /// Visibility "hidden": the video half of a live photo, never a photo of its own.
  var isHidden = false
}

/// Everything the server holds for this user that a rebuild needs: assets and this app's metadata.
/// Built from `/sync/stream` without acknowledging, so it always replays the full current state.
struct ServerIndex: Equatable {
  var assets: [String: ServerAsset] = [:]
  /// assetId → value under `ImmichClient.metadataKey`.
  var mirror: [String: MirrorMetadata] = [:]

  private struct Envelope<T: Decodable>: Decodable { let data: T }
  private struct Kind: Decodable { let type: String }
  private struct AssetV2: Decodable {
    let id: String
    let checksum: String
    let isFavorite: Bool
    let deletedAt: String?
    let libraryId: String?
    let livePhotoVideoId: String?
    let visibility: String?
  }
  private struct AssetRef: Decodable { let assetId: String }
  private struct Metadata: Decodable {
    let assetId: String
    let key: String
    let value: MirrorMetadata?
    private enum Keys: String, CodingKey { case assetId, key, value }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      assetId = try c.decode(String.self, forKey: .assetId)
      key = try c.decode(String.self, forKey: .key)
      // Other apps' metadata can hold any JSON: only this app's key is decoded.
      value =
        key == ImmichClient.metadataKey ? try? c.decode(MirrorMetadata.self, forKey: .value) : nil
    }
  }
  private struct MetadataRef: Decodable {
    let assetId: String
    let key: String
  }

  /// Applies one JSON line of the sync stream. Unknown types are ignored.
  mutating func apply(line: Data) throws {
    guard !line.isEmpty else { return }
    let d = JSONDecoder()
    switch try d.decode(Kind.self, from: line).type {
    case "AssetV2":
      let a = try d.decode(Envelope<AssetV2>.self, from: line).data
      assets[a.id] = ServerAsset(
        id: a.id, checksum: a.checksum, isFavorite: a.isFavorite, isTrashed: a.deletedAt != nil,
        isExternal: a.libraryId != nil, livePhotoVideoId: a.livePhotoVideoId,
        isHidden: a.visibility == "hidden")
    case "AssetDeleteV1":
      let id = try d.decode(Envelope<AssetRef>.self, from: line).data.assetId
      assets[id] = nil
      mirror[id] = nil
    case "AssetMetadataV1":
      let m = try d.decode(Envelope<Metadata>.self, from: line).data
      if let v = m.value { mirror[m.assetId] = v }
    case "AssetMetadataDeleteV1":
      let m = try d.decode(Envelope<MetadataRef>.self, from: line).data
      if m.key == ImmichClient.metadataKey { mirror[m.assetId] = nil }
    case "SyncResetV1":
      self = ServerIndex()
    default:
      break
    }
  }
}

struct SyncStreamRequest: Encodable { let types: [String] }

struct MetadataUpsertItem: Encodable {
  let key: String
  let value: MirrorMetadata
}
struct MetadataBulkUpsertItem: Encodable {
  let assetId: String
  let key: String
  let value: MirrorMetadata
}
struct MetadataBulkUpsertRequest: Encodable { let items: [MetadataBulkUpsertItem] }

struct AssetBulkDeleteRequest: Encodable {
  let ids: [String]
  let force: Bool
}
struct AssetBulkUpdateRequest: Encodable {
  let ids: [String]
  let isFavorite: Bool
}

struct BulkIdsRequest: Encodable { let ids: [String] }
struct BulkIdResponse: Decodable {
  let id: String
  let success: Bool
  let error: String?
}

struct AlbumDTO: Decodable {
  let id: String
  let albumName: String
  let description: String
  let assetCount: Int
}
struct CreateAlbumRequest: Encodable {
  let albumName: String
  let description: String
  let assetIds: [String]
}
struct UpdateAlbumRequest: Encodable {
  var albumName: String?
  var description: String?
}

// Search (v3 filter syntax)
struct SearchRequest: Encodable {
  struct Filter: Encodable {
    struct Ids: Encodable { let any: [String] }
    struct Str: Encodable { let eq: String }
    struct Pattern: Encodable { let startsWith: String }
    struct DateRange: Encodable {
      let gte: String
      let lte: String
    }
    var albumIds: Ids?
    var checksum: Str?
    var originalFileName: Pattern?
    var takenAt: DateRange?
  }
  let filter: Filter
  let size: Int
  let cursor: String?
}
struct SearchAsset: Decodable {
  let id: String
  let checksum: String
  let isTrashed: Bool
  var originalFileName: String?
  var originalPath: String?
  var originalMimeType: String?
  var libraryId: String?
  var fileCreatedAt: String?
}
struct SearchResponse: Decodable {
  struct Assets: Decodable {
    let items: [SearchAsset]
    let nextCursor: String?
  }
  let assets: Assets
}
