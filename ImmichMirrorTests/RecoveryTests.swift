import XCTest

@testable import ImmichMirror

/// Rebuilding the local mapping from the server (version 1.1).
final class RecoveryTests: XCTestCase {
  private func local(_ id: String, mod: Double = 100, fav: Bool = false) -> LocalAsset {
    LocalAsset(localId: id, modifiedAt: mod, isFavorite: fav)
  }

  /// A server photo uploaded by this app: metadata names the local and iCloud id.
  private func index(
    _ items: [(id: String, local: String, cloud: String?, mod: Double?)],
    trashed: Set<String> = [], external: Set<String> = [], favorite: Set<String> = [],
    videos: [String: String] = [:]
  ) -> ServerIndex {
    var i = ServerIndex()
    for it in items {
      i.assets[it.id] = ServerAsset(
        id: it.id, checksum: "sum-\(it.id)", isFavorite: favorite.contains(it.id),
        isTrashed: trashed.contains(it.id), isExternal: external.contains(it.id),
        livePhotoVideoId: videos[it.id])
      i.mirror[it.id] = MirrorMetadata(localId: it.local, cloudId: it.cloud, modifiedAt: it.mod)
    }
    return i
  }

  func testRelinksNewPhotosByCloudIdFromAnotherDevice() {
    let idx = index([(id: "s1", local: "OTHER-DEVICE/1", cloud: "c1", mod: 100)])
    let p = SyncPlanner.planRecovery(
      new: [local("L1")], local: [local("L1")], cloudIds: ["L1": "c1"], index: idx, mapped: [])
    XCTAssertEqual(p.adopt.map(\.record.immichId), ["s1"])
    XCTAssertEqual(p.adopt[0].record.localId, "L1")
    XCTAssertEqual(p.adopt[0].record.checksum, "sum-s1")
    XCTAssertFalse(p.adopt[0].edited)
    XCTAssertTrue(p.orphans.isEmpty)
  }

  func testFallsBackToLocalIdForOldUploadsWithoutCloudId() {
    let idx = index([(id: "s1", local: "L1", cloud: nil, mod: nil)])
    let p = SyncPlanner.planRecovery(
      new: [local("L1")], local: [local("L1")], cloudIds: ["L1": "c1"], index: idx, mapped: [])
    XCTAssertEqual(p.adopt.map(\.record.immichId), ["s1"])
    XCTAssertFalse(p.adopt[0].edited, "no recorded date: assumed unchanged")
  }

  func testEditedSinceUploadIsRecheckedAndTrashedCopyRestored() {
    let idx = index([(id: "s1", local: "x", cloud: "c1", mod: 50)], trashed: ["s1"])
    let p = SyncPlanner.planRecovery(
      new: [local("L1", mod: 100)], local: [local("L1", mod: 100)], cloudIds: ["L1": "c1"],
      index: idx, mapped: [])
    XCTAssertTrue(p.adopt[0].edited)
    XCTAssertEqual(p.adopt[0].record.modifiedAt, 50, "kept old date so the change is detected")
    XCTAssertEqual(p.adopt[0].restore, ["s1"])
  }

  func testPrefersCopyOutsideTrashThenNewestUpload() {
    let idx = index(
      [
        (id: "old", local: "x", cloud: "c1", mod: 10),
        (id: "new", local: "x", cloud: "c1", mod: 90),
        (id: "trashed", local: "x", cloud: "c1", mod: 99),
      ], trashed: ["trashed"])
    let p = SyncPlanner.planRecovery(
      new: [local("L1", mod: 90)], local: [local("L1", mod: 90)], cloudIds: ["L1": "c1"],
      index: idx, mapped: [])
    XCTAssertEqual(p.adopt.map(\.record.immichId), ["new"])
  }

  func testLivePhotoVideoComesAlongAndIsNeverAPhotoOrLeftover() {
    var idx = index(
      [
        (id: "still", local: "x", cloud: "c1", mod: 100),
        (id: "vid", local: "x", cloud: "c1", mod: 100),
      ],
      trashed: ["vid"], videos: ["still": "vid"])
    idx.mirror["vid"] = MirrorMetadata(localId: "x", cloudId: "c1", modifiedAt: 100)
    let p = SyncPlanner.planRecovery(
      new: [local("L1")], local: [local("L1")], cloudIds: ["L1": "c1"], index: idx, mapped: [])
    XCTAssertEqual(p.adopt.map(\.record.immichId), ["still"])
    XCTAssertEqual(p.adopt[0].record.liveVideoImmichId, "vid")
    XCTAssertEqual(p.adopt[0].restore, ["vid"])
    XCTAssertTrue(p.orphans.isEmpty)
  }

  func testLoneHiddenVideoIsNeverTakenForThePhoto() {
    var idx = index([(id: "vid", local: "x", cloud: "c1", mod: 100)])
    let v = idx.assets["vid"]!
    idx.assets["vid"] = ServerAsset(
      id: v.id, checksum: v.checksum, isFavorite: false, isTrashed: false, isExternal: false,
      livePhotoVideoId: nil, isHidden: true)
    let p = SyncPlanner.planRecovery(
      new: [local("L1")], local: [local("L1")], cloudIds: ["L1": "c-other"], index: idx, mapped: [])
    XCTAssertTrue(p.adopt.isEmpty)
    XCTAssertTrue(p.orphans.isEmpty)
  }

  func testNeverAdoptsExternalOrAlreadyMappedAssets() {
    let idx = index(
      [
        (id: "ext", local: "x", cloud: "c1", mod: 100),
        (id: "mine", local: "y", cloud: "c2", mod: 100),
      ],
      external: ["ext"])
    let p = SyncPlanner.planRecovery(
      new: [local("L1"), local("L2")], local: [local("L1"), local("L2")],
      cloudIds: ["L1": "c1", "L2": "c2"], index: idx, mapped: ["mine"])
    XCTAssertTrue(p.adopt.isEmpty)
    XCTAssertTrue(p.orphans.isEmpty, "mapped and external assets are handled elsewhere")
  }

  func testLeftoversAreThisAppsCopiesWhoseICloudPhotoIsGone() {
    let idx = index(
      [
        (id: "kept", local: "x", cloud: "c1", mod: 100),
        (id: "gone", local: "y", cloud: "c-deleted", mod: 100),
        (id: "gone-trashed", local: "z", cloud: "c-deleted-2", mod: 100),
        (id: "no-cloud-id", local: "w", cloud: nil, mod: 100),
      ], trashed: ["gone-trashed"])
    let p = SyncPlanner.planRecovery(
      new: [local("L1")], local: [local("L1")], cloudIds: ["L1": "c1"], index: idx, mapped: [])
    XCTAssertEqual(p.orphans.map(\.immichId), ["gone"])
  }

  func testLeftoverCheckSkippedWhenICloudIdsAreUnreliable() {
    let lib = (0..<100).map { local("L\($0)") }
    // iCloud ids for only 90 of 100 photos (10% missing).
    let ids = Dictionary(uniqueKeysWithValues: (0..<90).map { ("L\($0)", "c\($0)") })
    let idx = index([(id: "gone", local: "y", cloud: "c-deleted", mod: 100)])
    let p = SyncPlanner.planRecovery(new: [], local: lib, cloudIds: ids, index: idx, mapped: [])
    XCTAssertTrue(p.orphans.isEmpty)
    XCTAssertTrue(p.orphansSkipped)
  }

  func testSameLocalIdIsNotALeftoverEvenWithoutCloudIdMatch() {
    let idx = index([(id: "s1", local: "L1", cloud: "c-old", mod: 100)])
    let p = SyncPlanner.planRecovery(
      new: [], local: [local("L1")], cloudIds: ["L1": "c-new"], index: idx, mapped: [])
    XCTAssertTrue(p.orphans.isEmpty)
  }

  func testDeletionBlockCountsLeftoversAgainstServerSize() {
    let g = DeletionGuard(maxFraction: 0.05, alwaysAllowUpTo: 25)
    XCTAssertNil(
      SyncPlanner.deletionBlock(removing: 30, mirrored: 1000, localIsEmpty: false, guard: g).reason)
    XCTAssertNotNil(
      SyncPlanner.deletionBlock(removing: 60, mirrored: 1000, localIsEmpty: false, guard: g).reason)
    XCTAssertTrue(
      SyncPlanner.deletionBlock(removing: 1, mirrored: 10, localIsEmpty: true, guard: g).hard)
  }

  func testAlbumMarkerMatchesByLocalOrICloudId() {
    let marker = SyncPlanner.albumMarker("A/L0/040", cloudId: "cloud-1")
    XCTAssertEqual(marker, "immich-mirror:A/L0/040 cloud:cloud-1")
    XCTAssertTrue(SyncPlanner.albumMatches(description: marker, localId: "A/L0/040", cloudId: nil))
    XCTAssertTrue(
      SyncPlanner.albumMatches(description: marker, localId: "B/L0/040", cloudId: "cloud-1"))
    XCTAssertTrue(
      SyncPlanner.albumMatches(
        description: "immich-mirror:A/L0/040", localId: "A/L0/040", cloudId: "x"))
    XCTAssertFalse(
      SyncPlanner.albumMatches(description: marker, localId: "B/L0/040", cloudId: "cloud-2"))
    XCTAssertFalse(
      SyncPlanner.albumMatches(
        description: "My trip cloud:cloud-1", localId: "B", cloudId: "cloud-1"))
  }

  func testParsesSyncStreamLines() throws {
    var i = ServerIndex()
    let lines = [
      #"{"type":"AssetV2","data":{"id":"a1","checksum":"OOzS=","isFavorite":true,"deletedAt":null,"libraryId":null,"livePhotoVideoId":"v1","visibility":"timeline","ownerId":"u"},"ack":"x"}"#,
      #"{"type":"AssetV2","data":{"id":"v1","checksum":"VVV=","isFavorite":false,"deletedAt":"2026-01-01T00:00:00.000Z","libraryId":null,"livePhotoVideoId":null,"visibility":"hidden"},"ack":"x"}"#,
      #"{"type":"AssetV2","data":{"id":"gone","checksum":"G=","isFavorite":false,"deletedAt":null,"libraryId":"lib","livePhotoVideoId":null},"ack":"x"}"#,
      #"{"type":"AssetMetadataV1","data":{"assetId":"a1","key":"immich-mirror","value":{"localId":"L1","cloudId":"c1","modifiedAt":12.5}},"ack":"x"}"#,
      #"{"type":"AssetMetadataV1","data":{"assetId":"a1","key":"other-app","value":[1,2,3]},"ack":"x"}"#,
      #"{"type":"AssetMetadataV1","data":{"assetId":"gone","key":"immich-mirror","value":{"localId":"L9"}},"ack":"x"}"#,
      #"{"type":"AssetDeleteV1","data":{"assetId":"gone"},"ack":"x"}"#,
      #"{"type":"SyncCompleteV1","data":{},"ack":"x"}"#,
    ]
    for l in lines { try i.apply(line: Data(l.utf8)) }
    XCTAssertEqual(
      i.assets["a1"],
      ServerAsset(
        id: "a1", checksum: "OOzS=", isFavorite: true, isTrashed: false, isExternal: false,
        livePhotoVideoId: "v1"))
    XCTAssertTrue(i.assets["v1"]!.isTrashed)
    XCTAssertTrue(i.assets["v1"]!.isHidden)
    XCTAssertNil(i.assets["gone"])
    XCTAssertEqual(i.mirror, ["a1": MirrorMetadata(localId: "L1", cloudId: "c1", modifiedAt: 12.5)])
  }
}
