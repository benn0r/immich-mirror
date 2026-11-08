# App Store listing

Metadata for the Photo Mirror Sync App Store record, kept here so it can be reviewed and reused. App Store
Connect has the live version once the app exists. `npm run appstore:check` validates every language against
the App Store limits.

| Field | Source |
| --- | --- |
| Name | Photo Mirror Sync (same in every language; home screen: "Photo Mirror") |
| Subtitle (30) | `subtitle.txt` |
| Promotional text (170) | `promotional-text.txt` |
| Description (4000) | `description.txt` |
| Keywords (100) | `keywords.txt` |
| Support URL | `support-url.txt` (`{lang}` = folder name in lowercase) |
| Privacy policy URL | `privacy-policy-url.txt` (`{lang}` = folder name in lowercase) |
| Copyright | `copyright.txt` |
| App Review notes | `review-notes.txt` — **needs a demo Immich server and account** |
| Category | Photo & Video, secondary Utilities |
| Age rating | 4+ |
| Bundle ID | `ch.benn0r.immichmirror` (registered) |
| iPhone screenshots (1206×2622): home, dry-run, report, settings | `../screenshots/appstore/` (`npm run screenshots`, fictional `-demo` data) |
| Header (3840×1646) | `marketing/header-3840x1646.png` |
| Search results (1920×1280) | `marketing/search-results-1920x1280.png` |

The header and search-results backgrounds in `marketing/source/` were generated with OpenAI gpt-image-2 (bright
studio, photo prints on a mirror floor; deliberately unlike Off-hours), `source/icon.png` is exported from
`AppIcon.icon` with Icon Composer's `ictool`. `marketing/compose.py` (`npm run appstore:marketing`, needs Pillow)
adds the icon, the serif headline and the real app screenshot for every language. `npm run appstore:upload-folder`
collects everything per language in `upload/` (ignored by git) for drag and drop into App Store Connect.

English lives at the top level, every other language in `appstore/<lang>/` with the same four text files:
de, fr, it, es, nl, pt-PT, pt-BR, sv, da, nb, fi, ja, pl, zh-Hans, zh-Hant, ko, uk, cs, tr
(App Store Connect locales: de-DE, fr-FR, it, es-ES, nl-NL, pt-PT, pt-BR, sv, da, no, fi, ja, pl,
zh-Hans, zh-Hant, ko, uk, cs, tr).

## Rules followed

- **No "Immich" in subtitle or keywords** (other brands are not allowed there, guideline 2.3.7). The description
  names Immich only to state compatibility and ends with a non-affiliation note.
- **Keywords don't repeat words of the app name** (photo, mirror, sync are already indexed from the name).
- Keywords are comma-separated without spaces.

## App Privacy ("nutrition label")

Photos and the account go only to the user's own server; nothing is sent to the developer and there is no
analytics or tracking. In App Store Connect this is **"Data Not Collected"** (data sent to a server the user
operates is not collected by the developer).

## Before submission

1. Support and privacy policy pages live on photo-mirror-sync.tueftli.com (landing repo) in all 20 languages.
2. A reachable demo Immich server with a demo account for App Review, filled into `review-notes.txt`
   (do not commit real passwords — enter them in App Store Connect only).
3. Screenshots (iPhone 6.9"/6.3", 1206×2622) per language.
4. Release signing for App Store distribution (Apple Distribution certificate, `app-store-connect` export) and a
   listing upload command like Off-hours' `scripts/appstore.py listing`, once the app record (app ID) exists.
