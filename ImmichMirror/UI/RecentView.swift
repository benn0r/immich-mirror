import Photos
import SwiftUI

/// Last mirrored photos with direct links into Immich.
struct RecentView: View {
  @Environment(AppModel.self) private var model
  @State private var rows: [(MirrorRecord, String)] = []

  var body: some View {
    List {
      if rows.isEmpty { Text("Nothing mirrored yet").foregroundStyle(.secondary) }
      ForEach(rows, id: \.0.localId) { rec, name in
        if let base = model.session?.serverURL {
          Link(
            destination: base.appendingPathComponent("photos").appendingPathComponent(rec.immichId)
          ) {
            HStack {
              VStack(alignment: .leading) {
                Text(name).font(.subheadline)
                if rec.liveVideoImmichId != nil {
                  Text("Live Photo").font(.caption2).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Image(systemName: "arrow.up.right.square")
            }
          }
        }
      }
    }
    .navigationTitle("Recently Mirrored")
    .task { load() }
  }

  private func load() {
    guard let s = model.session, let store = try? MirrorStore(userId: s.email),
      let recs = try? store.recentAssets(limit: 200)
    else { return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: recs.map(\.localId), options: nil)
    var names: [String: String] = [:]
    assets.enumerateObjects { a, _, _ in
      names[a.localIdentifier] = PHAssetResource.assetResources(for: a).first?.originalFilename
    }
    rows = recs.map { ($0, names[$0.localId] ?? "(deleted in iCloud)") }
  }
}
