# Photo Mirror Sync

> [!IMPORTANT]
> **This entire repository, including the application, design, tests, documentation, and deployment setup was made with AI.**

Photo Mirror Sync is a small iPhone app that keeps your self-hosted [Immich](https://immich.app) server identical to your iCloud
Photos library. It is not a backup that only ever adds: new photos are uploaded, edited photos replaced,
favorites updated, **photos deleted in iCloud are moved to Immich's trash**, and regular iCloud albums are
mirrored as Immich albums. It is written in Swift and SwiftUI, talks only to your own Immich server and has no
other backend.

Built against Immich **v3.3** (API spec in `Docs/immich-openapi-3.3.6.json`). On the home screen the app is
called **Photo Mirror**; Xcode target, bundle ID (`ch.benn0r.immichmirror`) and the server-side markers keep
the original internal name `ImmichMirror` / `immich-mirror`.

## Features

- **Mirror, not backup**: iCloud is the source of truth. New, edited, favorited and deleted photos follow it.
- **Originals**: the current version of every photo (HEIC, ProRAW, video) is uploaded unchanged. Live Photos
  keep their motion part, linked like the official Immich app does it.
- **Albums**: regular iCloud albums (including those in folders, named `Folder / Album`) become Immich albums,
  kept in sync: created, renamed, filled, emptied, deleted. Albums you create in Immich are never touched.
- **Adopt instead of re-upload**: before uploading, the SHA-1 is checked against the server. Byte-identical
  copies already in Immich are linked instead of uploaded twice.
- **Dry run** (on by default): reports what would happen, estimates the upload size, and explains for a sample
  of photos why they are not on the server yet.
- **Background**: on iOS 26 a sync started in the app keeps running when you leave it, with progress on the
  lock screen. On top, an optional nightly sync while charging (BGProcessingTask).
- **Resumable**: every photo is recorded the moment it is on the server; a stopped, crashed or killed run
  continues where it left off without duplicates.
- **Recently mirrored**: the last 200 mirrored photos with direct links into Immich.
- **Liquid Glass icon**: layered `.icon`; sun, peaks and sync arrows are separate glass layers.

## How it works

One sync pass:

1. Scan the photo library (PhotoKit) and compare it with the local mapping (SQLite: iCloud id → Immich id).
2. Photos gone from iCloud → **Immich trash** (`force: false`).
3. Favorite-only changes → update the flag.
4. Edited photos → upload the new version, trash the old one.
5. New photos → download the original from iCloud if needed (4 at a time, stalled downloads skipped after
   1 minute), hash, `bulk-upload-check`, then adopt or upload with metadata `immich-mirror: {localId, cloudId}`.
6. Albums → create / rename / add / remove / delete to match iCloud. Each managed album carries the description
   `immich-mirror:<id>`, so the mapping can be rebuilt.

### Safety

- Only server assets and albums in the local mapping are ever changed. Everything else on the server
  (other uploads, external libraries, your own albums) is left alone, and external-library assets are never
  adopted.
- Deletes always go to Immich's trash; the app never empties it.
- More than 5 % of the library (minimum 25) deleted in one run needs your confirmation; background runs never
  confirm. An empty library or limited photo access never deletes anything.
- Full photo access is required: with limited access, unselected photos would look deleted.

## Requirements

- iPhone with iOS 17 or later (background continuation needs iOS 26).
- An Immich server (v3.3) and an account; the app signs in with email and password and keeps the session
  token in the Keychain.
- Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to build.

## Development

Copy `.env.example` to the ignored `.env` and set `IOS_DEVELOPMENT_TEAM` (and `IOS_DEVICE_ID` for
`npm run deploy`). Signing secrets for `npm run package` live in a 1Password Environment (see
[CI and releases](#ci-and-releases)); set its ID as `OP_ENVIRONMENT_ID` and the script loads them through the
1Password app with `op run --environment`. Project generation applies the team
every time, so regenerating `ImmichMirror.xcodeproj` does not lose it.

```sh
npm run ios           # generate the project and open it in Xcode
npm test              # unit tests with code coverage in the iPhone simulator
npm run test:unit     # unit tests only
npm run build         # unsigned Release build
npm run ios:release   # signed Release build
npm run deploy        # signed Release build installed and launched on IOS_DEVICE_ID
npm run package       # archive and export a development-signed IPA to .build/export
npm run icon          # regenerate the layered glass icon (Docs/icon/glass_icon.swift)
npm run lint && npm run format:check
npm run format        # swift-format in place
```

`ImmichMirror.xcodeproj` is generated from the tracked `project.yml`; change settings there and regenerate
instead of editing the project.

## Testing

Unit tests cover the pure sync decisions (`SyncPlanner`: new / changed / favorite / removed, deletion guards,
album plans, sampling), the SQLite mapping store and the multipart encoder. The I/O parts (PhotoKit, Immich API)
were verified against a real Immich 3.3.6 server and library.

## CI and releases

`.gitea/workflows/ci.yml` runs on every push and pull request on the self-hosted macOS runner: format check,
lint, unsigned Release build, unit tests. Tags don't run CI; they go to the release workflow.

`.gitea/workflows/release.yml` runs on tags `v*` (or by hand with a version): unit tests, archive, export of a
development-signed IPA and a Gitea release with the IPA and its SHA-256. The tag sets the version, the run
number the build number. It needs the team's Apple Development certificate in the runner's keychain.

Signing secrets are kept in a **1Password Environment** with the variables `IOS_DEVELOPMENT_TEAM`,
`ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (contents of the App Store Connect `.p8` key; pasted as-is or as
base64 — mangled line breaks are repaired, and an invalid key fails early). A 1Password
service account with read access to only that Environment provides them in CI; Gitea holds just the
secret `OP_SERVICE_ACCOUNT_TOKEN` and the variable `OP_ENVIRONMENT_ID`. Locally, the same Environment is read
through the 1Password app.

```sh
git tag v0.2.0 && git push origin v0.2.0
```

## Architecture

| Layer | File |
| --- | --- |
| Immich API (session bearer auth) | `ImmichMirror/API/ImmichClient.swift`, `ImmichModels.swift` |
| Mapping iCloud ↔ Immich (SQLite) | `ImmichMirror/Store/MirrorStore.swift`, `SQLite.swift`, `Keychain.swift` |
| PhotoKit: scan, streaming export + SHA-1, albums | `ImmichMirror/Photos/PhotoLibrary.swift` |
| Pure decision logic | `ImmichMirror/Sync/SyncPlanner.swift` |
| One sync pass | `ImmichMirror/Sync/SyncEngine.swift` |
| Background: continued task (iOS 26), nightly task | `ImmichMirror/Sync/ContinuedSync.swift`, `BackgroundSync.swift` |
| UI | `ImmichMirror/UI/*`, state in `ImmichMirror/App/AppModel.swift` |
| Icon | `ImmichMirror/AppIcon.icon` (generated by `Docs/icon/glass_icon.swift`) |

## License

MIT, see [LICENSE](LICENSE).

Photo Mirror Sync is an independent app that works with Immich servers. It is not affiliated with or
endorsed by the Immich project; "Immich" is a trademark of its owners and is used here only to describe
compatibility.
