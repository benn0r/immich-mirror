import Photos
import SwiftUI

struct HomeView: View {
  @Environment(AppModel.self) private var model
  @State private var confirmDeletion = false

  var body: some View {
    NavigationStack {
      List {
        accountSection
        if model.photoStatus != .authorized { accessSection }
        statusSection
        if let r = model.lastReport {
          ReportSection(report: r, onConfirmDeletion: { confirmDeletion = true })
        }
        logSection
      }
      .navigationTitle("Photo Mirror")
      .toolbar {
        NavigationLink {
          SettingsView()
        } label: {
          Image(systemName: "gearshape")
        }
      }
      .refreshable { model.refreshCounts() }
      .confirmationDialog(
        "Move \(model.lastReport?.pendingDeletions ?? 0) photos to the Immich trash?",
        isPresented: $confirmDeletion, titleVisibility: .visible
      ) {
        Button("Move to Trash", role: .destructive) { model.sync(confirmMassDeletion: true) }
      } message: {
        Text(
          "These photos are no longer in your iCloud library. They stay in Immich's trash until it is emptied (30 days by default)."
        )
      }
      .task { model.photoStatus = PhotoLibrary.status }
    }
  }

  private var accountSection: some View {
    Section {
      if let s = model.session {
        LabeledContent("Account", value: s.userName)
        LabeledContent("Server", value: s.serverURL.host() ?? s.serverURL.absoluteString)
      }
    }
  }

  private var accessSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Label(
          model.photoStatus == .limited
            ? LocalizedStringKey("Limited photo access")
            : LocalizedStringKey("Photo access needed"),
          systemImage: "photo.badge.exclamationmark"
        ).font(.headline)
        Text(
          "Photo Mirror needs full access. With limited access, unselected photos would look deleted."
        )
        .font(.subheadline).foregroundStyle(.secondary)
        if model.photoStatus == .notDetermined {
          Button("Allow Access") { Task { await model.requestPhotoAccess() } }.buttonStyle(
            .borderedProminent)
        } else {
          Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              UIApplication.shared.open(url)
            }
          }.buttonStyle(.bordered)
        }
      }.padding(.vertical, 4)
    }
  }

  private var statusSection: some View {
    Section {
      NavigationLink {
        RecentView()
      } label: {
        LabeledContent("Mirrored photos", value: model.mirroredCount.formatted())
      }
      LabeledContent(
        "Last sync", value: model.lastSync.flatMap(Self.formatDate) ?? String(localized: "Never"))
      if model.settings.dryRun {
        Label("Dry run mode — nothing will be changed", systemImage: "eye")
          .font(.footnote).foregroundStyle(.orange)
      }
      if let p = model.progress {
        VStack(alignment: .leading, spacing: 6) {
          Text(p.phase).font(.subheadline)
          if let d = p.detail {
            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          if p.total > 0 {
            ProgressView(value: Double(p.done), total: Double(p.total))
            Text("\(p.done) / \(p.total)").font(.caption).monospacedDigit().foregroundStyle(
              .secondary)
          } else {
            ProgressView().frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      if model.runsInBackground {
        Label("Keeps running when you leave the app", systemImage: "arrow.up.forward.app")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if let e = model.lastError {
        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
      }
      if model.isRunning {
        Button("Stop", role: .destructive) { model.cancel() }
      } else {
        Button {
          model.sync()
        } label: {
          Label(
            model.settings.dryRun
              ? LocalizedStringKey("Run Dry Run") : LocalizedStringKey("Sync Now"),
            systemImage: model.settings.dryRun ? "eye" : "arrow.triangle.2.circlepath")
        }
        .disabled(model.photoStatus != .authorized)
      }
    }
  }

  private var logSection: some View {
    Section("Log") {
      if model.log.isEmpty { Text("No activity yet").foregroundStyle(.secondary) }
      ForEach(model.log.prefix(50)) { line in
        VStack(alignment: .leading, spacing: 2) {
          Text(line.text).font(.footnote)
          Text(line.date, style: .time).font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }

  static func formatDate(_ iso: String) -> String? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso).map { $0.formatted(date: .abbreviated, time: .shortened) }
  }
}

struct ReportSection: View {
  @Environment(AppModel.self) private var model
  let report: SyncReport
  let onConfirmDeletion: () -> Void

  var body: some View {
    Section(report.dryRun ? LocalizedStringKey("Dry Run Result") : LocalizedStringKey("Last Sync"))
    {
      row("Photos in iCloud", report.localCount)
      row("New since last sync", report.newFound)
      if report.dryRun, report.estimatedUploadBytes > 0 {
        LabeledContent(
          "Upload size (new photos)",
          value: ByteCountFormatter.string(
            fromByteCount: report.estimatedUploadBytes, countStyle: .file))
      }
      if report.dryRun, report.sampled > 0 {
        let ratio = Double(report.sampleAdopt) / Double(max(report.sampled, 1))
        LabeledContent("Estimate (sample \(report.sampled))") {
          Text("\(Int(ratio * 100))% already on server").foregroundStyle(.secondary)
        }
        row("  · would adopt", report.sampleAdopt)
        row("  · would upload", report.sampleUpload)
      }
      if !report.dryRun {
        row("Uploaded", report.uploaded)
        row("Adopted (already on server)", report.adopted)
        row("Restored from trash", report.restored)
        row("Re-uploaded (edited)", report.reuploaded)
        row("Favorites updated", report.favoritesUpdated)
        row("Moved to trash", report.trashed)
      }
      row("Edited since last sync", report.changedFound)
      row(
        report.dryRun
          ? LocalizedStringKey("Would move to trash") : LocalizedStringKey("Pending deletions"),
        report.pendingDeletions)
      if report.albumsCreated + report.albumsRenamed + report.albumsDeleted
        + report.albumAssetsAdded + report.albumAssetsRemoved > 0
      {
        row("Albums created", report.albumsCreated)
        row("Albums renamed", report.albumsRenamed)
        row("Albums deleted", report.albumsDeleted)
        if !report.dryRun {
          row("Album photos added", report.albumAssetsAdded)
          row("Album photos removed", report.albumAssetsRemoved)
        }
      }
      if let reason = report.deletionBlockedReason {
        VStack(alignment: .leading, spacing: 8) {
          Label(reason, systemImage: "hand.raised").foregroundStyle(.orange).font(.footnote)
          if !report.dryRun, !report.deletionBlockedHard {
            Button("Review & Confirm…", action: onConfirmDeletion).buttonStyle(.bordered)
          }
        }
      }
      if report.cancelled {
        Label("Stopped before finishing", systemImage: "stop.circle").foregroundStyle(.secondary)
      }
      if !report.placed.isEmpty, let base = model.session?.serverURL {
        DisclosureGroup("Uploaded this run (\(report.placed.count))") {
          ForEach(report.placed, id: \.immichId) { p in
            Link(
              destination: base.appendingPathComponent("photos").appendingPathComponent(p.immichId)
            ) {
              HStack {
                Text(p.filename).font(.caption)
                Spacer()
                Text(p.how).font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "arrow.up.right.square").font(.caption)
              }
            }
          }
        }
      }
      if !report.diagnostics.isEmpty {
        DisclosureGroup("Why not on server? (\(report.diagnostics.count) examples)") {
          ForEach(Array(report.diagnostics.enumerated()), id: \.offset) { _, d in
            Text(d).font(.caption2).textSelection(.enabled)
          }
        }
      }
      if !report.failures.isEmpty {
        DisclosureGroup("\(report.failures.count) failures") {
          ForEach(Array(report.failures.prefix(100).enumerated()), id: \.offset) { _, f in
            Text(f).font(.caption).foregroundStyle(.red)
          }
        }
      }
    }
  }

  @ViewBuilder private func row(_ label: LocalizedStringKey, _ value: Int) -> some View {
    LabeledContent(label, value: value.formatted())
  }
}
