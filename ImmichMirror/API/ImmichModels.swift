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
struct MirrorMetadata: Codable, Equatable {
  var localId: String
  var cloudId: String?
}

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
struct UpdateAlbumRequest: Encodable { let albumName: String }

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
