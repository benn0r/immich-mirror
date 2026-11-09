import Foundation

enum ImmichError: LocalizedError {
  case badURL
  case http(Int, String)
  case unauthorized
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .badURL: return String(localized: "Invalid server URL")
    case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
    case .unauthorized: return String(localized: "Session expired — please sign in again")
    case .decoding(let s): return String(localized: "Unexpected server response: \(s)")
    }
  }
}

/// Thin client for the Immich endpoints Photo Mirror Sync needs. Auth via session bearer token.
final class ImmichClient: @unchecked Sendable {
  let baseURL: URL  // e.g. https://immich.example.com  (without /api)
  private let token: String?
  private let session: URLSession

  static let metadataKey = "immich-mirror"

  init(baseURL: URL, token: String?, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.token = token
    self.session = session
  }

  static func normalize(_ raw: String) -> URL? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !s.lowercased().hasPrefix("http") { s = "https://" + s }
    while s.hasSuffix("/") { s.removeLast() }
    if s.hasSuffix("/api") { s.removeLast(4) }
    return URL(string: s)
  }

  // MARK: - Core

  private func request(_ method: String, _ path: String, json: Encodable? = nil) throws
    -> URLRequest
  {
    guard let url = URL(string: baseURL.absoluteString + "/api" + path) else {
      throw ImmichError.badURL
    }
    var r = URLRequest(url: url)
    r.httpMethod = method
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let json {
      r.setValue("application/json", forHTTPHeaderField: "Content-Type")
      r.httpBody = try JSONEncoder().encode(AnyEncodable(json))
    }
    r.timeoutInterval = 60
    return r
  }

  private func check(_ data: Data, _ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else { throw ImmichError.http(-1, "no response") }
    if http.statusCode == 401 { throw ImmichError.unauthorized }
    guard (200..<300).contains(http.statusCode) else {
      throw ImmichError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
  }

  private func send<T: Decodable>(
    _ method: String, _ path: String, json: Encodable? = nil, as: T.Type
  ) async throws -> T {
    let (data, resp) = try await session.data(for: request(method, path, json: json))
    try check(data, resp)
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw ImmichError.decoding("\(path): \(error)")
    }
  }

  private func sendNoContent(_ method: String, _ path: String, json: Encodable? = nil) async throws
  {
    let (data, resp) = try await session.data(for: request(method, path, json: json))
    try check(data, resp)
  }

  // MARK: - Auth & server

  func serverVersion() async throws -> ServerVersion {
    try await send("GET", "/server/version", as: ServerVersion.self)
  }

  func login(email: String, password: String) async throws -> LoginResponse {
    try await send(
      "POST", "/auth/login", json: LoginRequest(email: email, password: password),
      as: LoginResponse.self)
  }

  func validateToken() async throws -> Bool {
    try await send("POST", "/auth/validateToken", as: ValidateTokenResponse.self).authStatus
  }

  func logout() async throws { try await sendNoContent("POST", "/auth/logout") }

  func me() async throws -> UserMe { try await send("GET", "/users/me", as: UserMe.self) }

  // MARK: - Assets

  func bulkUploadCheck(_ items: [BulkUploadCheckItem]) async throws -> [BulkUploadCheckResult] {
    try await send(
      "POST", "/assets/bulk-upload-check", json: BulkUploadCheckRequest(assets: items),
      as: BulkUploadCheckResponse.self
    ).results
  }

  struct UploadParams {
    var fileURL: URL
    var filename: String
    var mimeType: String
    var checksumHex: String
    var createdAt: Date
    var modifiedAt: Date
    var isFavorite: Bool
    var durationMs: Int?
    var livePhotoVideoId: String?
    var visibility: String?  // "hidden" for the video half of a live photo
    var metadata: MirrorMetadata
  }

  func upload(_ p: UploadParams, onProgress: (@Sendable (Double) -> Void)? = nil) async throws
    -> UploadResponse
  {
    let boundary = "ImmichMirror-\(UUID().uuidString)"
    let bodyURL = try Multipart.write(
      boundary: boundary, fields: uploadFields(p), fileField: "assetData",
      fileURL: p.fileURL, filename: p.filename, mimeType: p.mimeType)
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    var r = try request("POST", "/assets")
    r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    r.setValue(p.checksumHex, forHTTPHeaderField: "x-immich-checksum")
    r.timeoutInterval = 600
    let delegate = onProgress.map(UploadProgressDelegate.init)
    let (data, resp) = try await session.upload(for: r, fromFile: bodyURL, delegate: delegate)
    try check(data, resp)
    do { return try JSONDecoder().decode(UploadResponse.self, from: data) } catch {
      throw ImmichError.decoding("upload: \(error)")
    }
  }

  private func uploadFields(_ p: UploadParams) throws -> [(String, String)] {
    let meta = try JSONEncoder().encode([
      MetadataUpsertItem(key: Self.metadataKey, value: p.metadata)
    ])
    var f: [(String, String)] = [
      ("fileCreatedAt", ISO8601.string(p.createdAt)),
      ("fileModifiedAt", ISO8601.string(p.modifiedAt)),
      ("filename", p.filename),
      ("isFavorite", p.isFavorite ? "true" : "false"),
      ("metadata", String(decoding: meta, as: UTF8.self)),
    ]
    if let d = p.durationMs { f.append(("duration", String(d))) }
    if let v = p.livePhotoVideoId { f.append(("livePhotoVideoId", v)) }
    if let v = p.visibility { f.append(("visibility", v)) }
    return f
  }

  func assetInfo(id: String) async throws -> AssetInfo {
    try await send("GET", "/assets/\(id)", as: AssetInfo.self)
  }

  func upsertMetadata(_ items: [MetadataBulkUpsertItem]) async throws {
    guard !items.isEmpty else { return }
    try await sendNoContent(
      "PUT", "/assets/metadata", json: MetadataBulkUpsertRequest(items: items))
  }

  func setFavorite(ids: [String], _ fav: Bool) async throws {
    guard !ids.isEmpty else { return }
    try await sendNoContent(
      "PUT", "/assets", json: AssetBulkUpdateRequest(ids: ids, isFavorite: fav))
  }

  /// Soft delete only — assets go to Immich's trash. This app never force-deletes.
  func trash(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    try await sendNoContent(
      "DELETE", "/assets", json: AssetBulkDeleteRequest(ids: ids, force: false))
  }

  /// Brings assets back from Immich's trash (used when a photo still exists in iCloud).
  func restoreFromTrash(ids: [String]) async throws {
    guard !ids.isEmpty else { return }
    let (data, resp) = try await session.data(
      for: request("POST", "/trash/restore/assets", json: BulkIdsRequest(ids: ids)))
    try check(data, resp)
  }

  /// All of the user's assets and this app's metadata, from the sync stream (the protocol Immich's own
  /// app uses). Nothing is acknowledged, so every call replays the full current state and no other
  /// session's sync position changes. Needs a session token (API keys can't use the stream).
  func serverIndex() async throws -> ServerIndex {
    var r = try request(
      "POST", "/sync/stream", json: SyncStreamRequest(types: ["AssetsV2", "AssetMetadataV1"]))
    r.setValue("application/jsonlines+json", forHTTPHeaderField: "Accept")
    r.timeoutInterval = 300
    let (bytes, resp) = try await session.bytes(for: r)
    guard let http = resp as? HTTPURLResponse else { throw ImmichError.http(-1, "no response") }
    if http.statusCode == 401 { throw ImmichError.unauthorized }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      for try await b in bytes {
        body.append(b)
        if body.count > 2000 { break }
      }
      throw ImmichError.http(http.statusCode, String(decoding: body, as: UTF8.self))
    }
    var index = ServerIndex()
    for try await line in bytes.lines {
      do { try index.apply(line: Data(line.utf8)) } catch {
        throw ImmichError.decoding("sync stream: \(error)")
      }
    }
    return index
  }

  /// Single page, for diagnostics.
  func searchFirst(_ filter: SearchRequest.Filter, size: Int = 5) async throws -> [SearchAsset] {
    try await send(
      "POST", "/search/metadata", json: SearchRequest(filter: filter, size: size, cursor: nil),
      as: SearchResponse.self
    ).assets.items
  }

  func search(_ filter: SearchRequest.Filter) async throws -> [SearchAsset] {
    var out: [SearchAsset] = []
    var cursor: String? = nil
    repeat {
      let page = try await send(
        "POST", "/search/metadata",
        json: SearchRequest(filter: filter, size: 1000, cursor: cursor), as: SearchResponse.self)
      out += page.assets.items
      cursor = page.assets.nextCursor
    } while cursor != nil
    return out
  }

  // MARK: - Albums

  func albums() async throws -> [AlbumDTO] { try await send("GET", "/albums", as: [AlbumDTO].self) }

  func album(id: String) async throws -> AlbumDTO? {
    do { return try await send("GET", "/albums/\(id)", as: AlbumDTO.self) } catch ImmichError.http(
      let code, _) where code == 400 || code == 404
    { return nil }
  }

  func createAlbum(name: String, description: String, assetIds: [String]) async throws -> AlbumDTO {
    try await send(
      "POST", "/albums",
      json: CreateAlbumRequest(albumName: name, description: description, assetIds: assetIds),
      as: AlbumDTO.self)
  }

  func renameAlbum(id: String, name: String) async throws {
    _ = try await send(
      "PATCH", "/albums/\(id)", json: UpdateAlbumRequest(albumName: name), as: AlbumDTO.self)
  }

  func setAlbumDescription(id: String, _ description: String) async throws {
    _ = try await send(
      "PATCH", "/albums/\(id)", json: UpdateAlbumRequest(description: description),
      as: AlbumDTO.self)
  }

  func addToAlbum(id: String, assetIds: [String]) async throws {
    for chunk in assetIds.chunked(500) {
      _ = try await send(
        "PUT", "/albums/\(id)/assets", json: BulkIdsRequest(ids: chunk), as: [BulkIdResponse].self)
    }
  }

  func removeFromAlbum(id: String, assetIds: [String]) async throws {
    for chunk in assetIds.chunked(500) {
      _ = try await send(
        "DELETE", "/albums/\(id)/assets", json: BulkIdsRequest(ids: chunk),
        as: [BulkIdResponse].self)
    }
  }

  func deleteAlbum(id: String) async throws { try await sendNoContent("DELETE", "/albums/\(id)") }

  func albumAssetIds(id: String) async throws -> Set<String> {
    Set(try await search(.init(albumIds: .init(any: [id]))).filter { !$0.isTrashed }.map(\.id))
  }
}

// MARK: - Helpers

struct AnyEncodable: Encodable {
  let value: Encodable
  init(_ v: Encodable) { value = v }
  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

enum ISO8601 {
  private static let f: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  static func string(_ d: Date) -> String { f.string(from: d) }
}

enum Multipart {
  /// Streams a multipart body to a temp file so large videos never sit in memory.
  static func write(
    boundary: String, fields: [(String, String)], fileField: String,
    fileURL: URL, filename: String, mimeType: String
  ) throws -> URL {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(
      "upload-\(UUID().uuidString).body")
    FileManager.default.createFile(atPath: out.path, contents: nil)
    let h = try FileHandle(forWritingTo: out)
    defer { try? h.close() }
    func w(_ s: String) throws { try h.write(contentsOf: Data(s.utf8)) }
    for (k, v) in fields {
      try w("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
    }
    let safeName = filename.replacingOccurrences(of: "\"", with: "_")
    try w(
      "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
    )
    let input = try FileHandle(forReadingFrom: fileURL)
    defer { try? input.close() }
    while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
      try h.write(contentsOf: chunk)
    }
    try w("\r\n--\(boundary)--\r\n")
    return out
  }
}

extension Array {
  func chunked(_ size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
  }
}

/// Reports the fraction of the request body sent (keeps background progress moving during big uploads).
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let onProgress: @Sendable (Double) -> Void
  init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64, totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }
    onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
  }
}
