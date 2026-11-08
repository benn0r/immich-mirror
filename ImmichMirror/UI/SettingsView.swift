import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var confirmReset = false
  @State private var confirmSignOut = false

  var body: some View {
    @Bindable var model = model
    Form {
      Section {
        Toggle("Dry run", isOn: $model.settings.dryRun)
        Toggle("Mirror albums", isOn: $model.settings.syncAlbums)
      } footer: {
        Text(
          "Dry run reports what would happen without changing anything on the server. Albums: regular iCloud albums are mirrored (folders flattened as “Folder / Album”). Albums you create in Immich yourself are never touched."
        )
      }

      Section {
        Picker("Upload limit per run", selection: $model.settings.uploadLimit) {
          Text("No limit").tag(0)
          Text("25 photos").tag(25)
          Text("100 photos").tag(100)
          Text("1,000 photos").tag(1000)
        }
      } footer: {
        Text(
          "Use a small limit for a first test run, check the result in Immich, then set it back to “No limit”. Albums are mirrored with whatever photos are uploaded so far and fill up on later runs."
        )
      }

      Section {
        Stepper(
          "Block above \(Int(model.settings.deletionGuard.maxFraction * 100))% of library",
          value: $model.settings.deletionGuard.maxFraction, in: 0.01...0.5, step: 0.01)
        Stepper(
          "Always allow up to \(model.settings.deletionGuard.alwaysAllowUpTo)",
          value: $model.settings.deletionGuard.alwaysAllowUpTo, in: 0...500, step: 5)
      } header: {
        Text("Deletion Safety")
      } footer: {
        Text(
          "Deleted photos always go to Immich's trash, never straight to permanent deletion. Larger deletions wait for your confirmation; background sync never confirms them."
        )
      }

      Section {
        Toggle("Notify when a sync finishes", isOn: $model.notifyOnFinish)
      } footer: {
        Text(
          "A summary of what was uploaded, trashed and changed in albums — when the sync ends while you are not in the app. Nightly syncs only notify when something changed."
        )
      }

      Section {
        Toggle("Background sync", isOn: $model.backgroundSyncEnabled)
          .disabled(model.settings.dryRun)
      } footer: {
        Text(
          "iOS runs it when it sees fit, usually overnight while charging. Turn off dry run to enable."
        )
      }

      Section {
        Button("Reset Local Mapping…", role: .destructive) { confirmReset = true }
        Button("Sign Out", role: .destructive) { confirmSignOut = true }
      } footer: {
        Text(
          "Resetting forgets which server photos belong to which iCloud photo. Nothing on the server is changed; the next sync re-links photos by checksum."
        )
      }
    }
    .navigationTitle("Settings")
    .confirmationDialog(
      "Reset local mapping?", isPresented: $confirmReset, titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) { model.resetMapping() }
    }
    .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
      Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
    }
  }
}
