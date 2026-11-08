import XCTest

@testable import ImmichMirror

final class SyncPlannerTests: XCTestCase {
  private func rec(_ id: String, mod: Double = 1, fav: Bool = false) -> MirrorRecord {
    MirrorRecord(
      localId: id, cloudId: nil, immichId: "im-\(id)", liveVideoImmichId: nil, checksum: "c",
      modifiedAt: mod, isFavorite: fav)
  }
  private func local(_ id: String, mod: Double = 1, fav: Bool = false) -> LocalAsset {
    LocalAsset(localId: id, modifiedAt: mod, isFavorite: fav)
  }
  private func stored(_ recs: [MirrorRecord]) -> [String: MirrorRecord] {
    Dictionary(uniqueKeysWithValues: recs.map { ($0.localId, $0) })
  }

  func testClassifiesNewChangedFavoriteRemoved() {
    let p = SyncPlanner.planAssets(
      local: [local("a"), local("b", mod: 5), local("c", fav: true), local("new")],
      stored: stored([rec("a"), rec("b"), rec("c"), rec("gone")]),
      guard: .init())
    XCTAssertEqual(p.new, ["new"])
    XCTAssertEqual(p.changed, ["b"])
    XCTAssertEqual(p.favoriteOnly, ["c"])
    XCTAssertEqual(p.removed.map(\.localId), ["gone"])
    XCTAssertFalse(p.deletionBlocked)
  }

  func testEmptyLibraryNeverDeletes() {
    let p = SyncPlanner.planAssets(
      local: [], stored: stored([rec("a")]), guard: .init(maxFraction: 1, alwaysAllowUpTo: 1000))
    XCTAssertTrue(p.deletionBlocked)
  }

  func testMassDeletionBlockedAboveThreshold() {
    let all = (0..<1000).map { rec("p\($0)") }
    let keep = (0..<900).map { local("p\($0)") }  // 100 removed = 10%
    let p = SyncPlanner.planAssets(
      local: keep, stored: stored(all), guard: .init(maxFraction: 0.05, alwaysAllowUpTo: 25))
    XCTAssertEqual(p.removed.count, 100)
    XCTAssertTrue(p.deletionBlocked)
  }

  func testSmallDeletionAllowedEvenOnSmallLibrary() {
    let all = (0..<40).map { rec("p\($0)") }
    let keep = (0..<20).map { local("p\($0)") }  // 50% but only 20 photos
    let p = SyncPlanner.planAssets(
      local: keep, stored: stored(all), guard: .init(maxFraction: 0.05, alwaysAllowUpTo: 25))
    XCTAssertFalse(p.deletionBlocked)
  }

  func testDeletionWithinFractionAllowed() {
    let all = (0..<10_000).map { rec("p\($0)") }
    let keep = (0..<9_600).map { local("p\($0)") }  // 4%
    let p = SyncPlanner.planAssets(local: keep, stored: stored(all), guard: .init())
    XCTAssertFalse(p.deletionBlocked)
    XCTAssertEqual(p.removed.count, 400)
  }

  func testAlbumPlan() {
    let localAlbums = [
      LocalAlbum(localId: "A", name: "Trip", assetLocalIds: []),
      LocalAlbum(localId: "B", name: "Renamed", assetLocalIds: []),
      LocalAlbum(localId: "C", name: "Fresh", assetLocalIds: []),
    ]
    let storedAlbums = [
      "A": AlbumRecord(localId: "A", immichId: "x", name: "Trip"),
      "B": AlbumRecord(localId: "B", immichId: "y", name: "Old"),
      "D": AlbumRecord(localId: "D", immichId: "z", name: "Deleted"),
    ]
    let p = SyncPlanner.planAlbums(local: localAlbums, stored: storedAlbums)
    XCTAssertEqual(p.create.map(\.localId), ["C"])
    XCTAssertEqual(p.rename.map(\.newName), ["Renamed"])
    XCTAssertEqual(p.delete.map(\.localId), ["D"])
    XCTAssertEqual(Set(p.keep.map(\.local.localId)), ["A", "B"])
    XCTAssertNil(p.deletionBlockedReason)
  }

  func testNoLocalAlbumsBlocksAlbumDeletion() {
    let p = SyncPlanner.planAlbums(
      local: [], stored: ["D": AlbumRecord(localId: "D", immichId: "z", name: "x")])
    XCTAssertNotNil(p.deletionBlockedReason)
  }

  func testSpreadSample() {
    let s = SyncPlanner.spreadSample(Array(0..<1000), count: 4)
    XCTAssertEqual(s, [0, 250, 500, 750])
    XCTAssertEqual(SyncPlanner.spreadSample([1, 2], count: 10), [1, 2])
  }

  func testDesiredMembersSkipsUnmapped() {
    let a = LocalAlbum(localId: "A", name: "x", assetLocalIds: ["a", "b", "unmapped"])
    let m = SyncPlanner.desiredMembers(a, mapping: stored([rec("a"), rec("b")]))
    XCTAssertEqual(m, ["im-a", "im-b"])
  }
}

final class MirrorStoreTests: XCTestCase {
  func testRoundTrip() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).sqlite")
      .path
    let s = try MirrorStore(path: path)
    let r = MirrorRecord(
      localId: "l1", cloudId: "c1", immichId: "i1", liveVideoImmichId: "v1", checksum: "abc=",
      modifiedAt: 12.5, isFavorite: true)
    try s.upsert(r)
    XCTAssertEqual(try s.allAssets()["l1"], r)
    var r2 = r
    r2.immichId = "i2"
    r2.liveVideoImmichId = nil
    try s.upsert(r2)
    XCTAssertEqual(try s.allAssets()["l1"], r2)
    XCTAssertEqual(try s.assetCount(), 1)
    try s.upsert(AlbumRecord(localId: "A", immichId: "x", name: "Trip"))
    XCTAssertEqual(try s.allAlbums()["A"]?.name, "Trip")
    try s.set("k", "v")
    XCTAssertEqual(try s.get("k"), "v")
    try s.deleteAsset(localId: "l1")
    XCTAssertEqual(try s.assetCount(), 0)
  }

  func testMultipartAndNormalize() throws {
    XCTAssertEqual(
      ImmichClient.normalize("immich.example.com/api/")?.absoluteString,
      "https://immich.example.com")
    let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID())")
    try Data("HELLO".utf8).write(to: src)
    let out = try Multipart.write(
      boundary: "B", fields: [("a", "1")], fileField: "f", fileURL: src, filename: "x.jpg",
      mimeType: "image/jpeg")
    let body = try String(contentsOf: out, encoding: .utf8)
    XCTAssertEqual(
      body,
      "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--B\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nHELLO\r\n--B--\r\n"
    )
  }
}

final class SyncNotifierTests: XCTestCase {
  private func report(_ edit: (inout SyncReport) -> Void) -> SyncReport {
    var r = SyncReport(dryRun: false)
    r.localCount = 48_573
    r.mirroredAfter = 48_573
    edit(&r)
    return r
  }

  func testUpToDate() {
    let (title, body) = SyncNotifier.summary(report { _ in })
    XCTAssertEqual(title, "Sync finished")
    XCTAssertTrue(body.hasPrefix("Everything up to date."))
    XCTAssertFalse(SyncNotifier.hasNews(report { _ in }))
  }

  func testCountsAndPlurals() {
    let r = report {
      $0.uploaded = 120
      $0.trashed = 1
      $0.albumsCreated = 2
    }
    let body = SyncNotifier.summary(r).body
    XCTAssertTrue(body.contains("photos uploaded"), body)
    XCTAssertTrue(body.contains("1 moved to trash"), body)
    XCTAssertTrue(body.contains("2 albums created"), body)
    XCTAssertTrue(SyncNotifier.hasNews(r))
  }

  func testStoppedAndBlockedAndFailures() {
    let r = report {
      $0.cancelled = true
      $0.deletionBlockedReason = "too many"
      $0.pendingDeletions = 300
      $0.failures = ["a", "b"]
    }
    let (title, body) = SyncNotifier.summary(r)
    XCTAssertEqual(title, "Sync stopped")
    XCTAssertTrue(body.contains("300 deletions wait for your confirmation."), body)
    XCTAssertTrue(body.contains("2 items failed."), body)
    XCTAssertTrue(body.contains("Continues where it left off"), body)
  }
}
