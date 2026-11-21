import Photos
import SwiftUI

/// Items the last sync could not mirror. Photos with a library ID show a thumbnail, name and date,
/// and open a detail page that sends the user to the Photos app to fix them.
struct FailedItemsGroup: View {
  let failures: [SyncFailure]

  var body: some View {
    DisclosureGroup("\(failures.count) failures") {
      ForEach(Array(failures.prefix(100).enumerated()), id: \.offset) { _, f in
        if let id = f.localId, let asset = FailedAsset(localId: id) {
          NavigationLink {
            FailedAssetDetail(asset: asset, message: f.message)
          } label: {
            FailedAssetRow(asset: asset, message: f.message)
          }
        } else {
          Text(f.message).font(.caption).foregroundStyle(.red)
        }
      }
    }
  }
}

/// The library side of a failed item: what the user needs to find it in Photos.
struct FailedAsset {
  let asset: PHAsset
  let filename: String

  init?(localId: String) {
    guard
      let a = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject
    else { return nil }
    asset = a
    filename =
      PHAssetResource.assetResources(for: a).first?.originalFilename
      ?? String(localized: "(no file name)")
  }

  var date: String {
    asset.creationDate?.formatted(date: .long, time: .shortened) ?? String(localized: "(no date)")
  }
}

private struct FailedAssetRow: View {
  let asset: FailedAsset
  let message: String

  var body: some View {
    HStack(spacing: 12) {
      AssetThumbnail(asset: asset.asset, side: 52)
      VStack(alignment: .leading, spacing: 2) {
        Text(asset.filename).font(.subheadline)
        Text(asset.date).font(.caption).foregroundStyle(.secondary)
        Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
      }
    }
  }
}

struct FailedAssetDetail: View {
  let asset: FailedAsset
  let message: String
  @Environment(\.openURL) private var openURL

  var body: some View {
    List {
      Section {
        AssetThumbnail(asset: asset.asset, side: 280)
          .frame(maxWidth: .infinity)
          .listRowBackground(Color.clear)
      }
      Section {
        LabeledContent("File", value: asset.filename)
        LabeledContent("Taken", value: asset.date)
        Text(message).font(.footnote).foregroundStyle(.red)
      }
      Section {
        Button {
          // iOS has no public link to one photo; this opens the Photos app.
          if let url = URL(string: "photos-redirect://") { openURL(url) }
        } label: {
          Label("Open Photos", systemImage: "photo.on.rectangle")
        }
      } footer: {
        Text(
          "Find the photo by its date and open it in full size, so iCloud downloads the original. The next sync picks it up. If Photos can't load it either, the copy in iCloud is damaged."
        )
      }
    }
    .navigationTitle(asset.filename)
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Square thumbnail from the library; allowed to fetch a small preview from iCloud.
private struct AssetThumbnail: View {
  let asset: PHAsset
  let side: CGFloat
  @State private var image: UIImage?
  @Environment(\.displayScale) private var scale

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8).fill(.quaternary)
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: asset.mediaType == .video ? "video" : "photo")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .task(id: asset.localIdentifier) {
      let opts = PHImageRequestOptions()
      opts.isNetworkAccessAllowed = true
      opts.deliveryMode = .opportunistic
      let px = side * scale
      PHImageManager.default().requestImage(
        for: asset, targetSize: CGSize(width: px, height: px), contentMode: .aspectFill,
        options: opts
      ) { img, _ in
        if let img { Task { @MainActor in image = img } }
      }
    }
  }
}
