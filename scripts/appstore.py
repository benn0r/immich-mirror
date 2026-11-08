"""Small App Store Connect API client for Photo Mirror Sync (official API, no third-party services).

Needs an App Store Connect API key (App Manager role) saved as
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 and `pip install pyjwt cryptography`.
The key is only read to sign requests; it is never printed.

    export ASC_KEY_ID=… ASC_ISSUER_ID=…
    python3 scripts/appstore.py status
    python3 scripts/appstore.py all                                  # listing, details, screenshots, images for every language
    python3 scripts/appstore.py details                              # categories, age rating, copyright, rights, price
    python3 scripts/appstore.py screenshots de pt-PT pt-BR          # upload into empty sets
    python3 scripts/appstore.py screenshots de --replace             # replace existing ones
    python3 scripts/appstore.py assets de pt-PT pt-BR               # header + search results images
    python3 scripts/appstore.py listing sv da                        # name, subtitle, description, keywords, …
    python3 scripts/appstore.py submit                               # attach the newest build, submit for review
    python3 scripts/appstore.py next-build                           # highest uploaded build number + 1
    python3 scripts/appstore.py wait-build 5                         # wait until build 5 has processed
Set ASC_KEY_PATH to read the key from another path (CI).
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt

ROOT = Path(__file__).resolve().parent.parent
APP_ID = "6832342980"
NAME = "Photo Mirror Sync"
API = "https://api.appstoreconnect.apple.com/v1"
# 1206×2622 screenshots belong to the 6.1"/6.3" iPhone slot ("iPhone with Dynamic Island").
DISPLAY_TYPE = "APP_IPHONE_61"
SCREENS = ["home", "dry-run", "report", "settings"]
# Folder name in screenshots/appstore → App Store Connect locale.
LOCALES = {
    "en": "en-US",
    "de": "de-DE",
    "fr": "fr-FR",
    "it": "it",
    "es": "es-ES",
    "nl": "nl-NL",
    "pt-PT": "pt-PT",
    "pt-BR": "pt-BR",
    "sv": "sv",
    "da": "da",
    "nb": "no",
    "fi": "fi",
    "ja": "ja",
    "pl": "pl",
    "zh-Hans": "zh-Hans",
    "zh-Hant": "zh-Hant",
    "ko": "ko",
    "uk": "uk",
    "cs": "cs",
    "tr": "tr",
}


def configured(name: str) -> str | None:
    """A value from appstore/<name>.txt, or None while it is still a <PLACEHOLDER>.
    `{lang}` in the support and privacy URLs is the folder name in lowercase (de, pt-pt, zh-hans, nb, …)."""
    value = (ROOT / "appstore" / f"{name}.txt").read_text().strip()
    return None if not value or value.startswith("<") else value


def token() -> str:
    key_id = os.environ["ASC_KEY_ID"]
    issuer = os.environ["ASC_ISSUER_ID"]
    default = Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{key_id}.p8"
    key = Path(os.environ.get("ASC_KEY_PATH") or default).read_text()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    url = path if path.startswith("http") else API + path
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:600]
        raise SystemExit(f"{method} {path} → {error.code}\n{detail}") from None


def editable_version() -> dict:
    versions = call("GET", f"/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&limit=10")["data"]
    for version in versions:
        if version["attributes"]["appStoreState"] in {
            "PREPARE_FOR_SUBMISSION",
            "DEVELOPER_REJECTED",
            "REJECTED",
            "METADATA_REJECTED",
        }:
            return version
    raise SystemExit("No editable App Store version (it may be in review or released).")


def localizations(version_id: str) -> dict[str, str]:
    data = call("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=50")["data"]
    return {item["attributes"]["locale"]: item["id"] for item in data}


def screenshot_set(localization_id: str) -> tuple[str, list[str]]:
    sets = call(
        "GET",
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets"
        f"?filter[screenshotDisplayType]={DISPLAY_TYPE}&include=appScreenshots&limit=10",
    )
    for item in sets["data"]:
        shots = [s["id"] for s in item["relationships"]["appScreenshots"].get("data", [])]
        return item["id"], shots
    created = call(
        "POST",
        "/appScreenshotSets",
        {
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {"type": "appStoreVersionLocalizations", "id": localization_id}
                    }
                },
            }
        },
    )
    return created["data"]["id"], []


def upload(set_id: str, file: Path) -> str:
    content = file.read_bytes()
    reservation = call(
        "POST",
        "/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": file.name, "fileSize": len(content)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
            }
        },
    )["data"]
    for operation in reservation["attributes"]["uploadOperations"]:
        chunk = content[operation["offset"] : operation["offset"] + operation["length"]]
        request = urllib.request.Request(operation["url"], data=chunk, method=operation["method"])
        for header in operation.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        with urllib.request.urlopen(request):
            pass
    call(
        "PATCH",
        f"/appScreenshots/{reservation['id']}",
        {
            "data": {
                "type": "appScreenshots",
                "id": reservation["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(content).hexdigest()},
            }
        },
    )
    return reservation["id"]


def wait_until_processed(ids: list[str]) -> dict[str, str]:
    states: dict[str, str] = {}
    for _ in range(60):
        for shot_id in ids:
            delivery = call("GET", f"/appScreenshots/{shot_id}")["data"]["attributes"]["assetDeliveryState"]
            states[shot_id] = delivery["state"]
            if delivery["state"] == "FAILED":
                raise SystemExit(f"Screenshot {shot_id} failed: {delivery.get('errors')}")
        if all(state == "COMPLETE" for state in states.values()):
            break
        time.sleep(3)
    return states


def screenshots(folders: list[str], replace: bool) -> None:
    version = editable_version()
    locs = localizations(version["id"])
    for folder in folders:
        locale = LOCALES[folder]
        if locale not in locs:
            print(f"{folder}: no {locale} localization on version {version['attributes']['versionString']}")
            continue
        set_id, existing = screenshot_set(locs[locale])
        if existing and not replace:
            print(f"{folder}: {len(existing)} screenshots already there, skipped (use --replace)")
            continue
        for shot_id in existing:
            call("DELETE", f"/appScreenshots/{shot_id}")
        source = ROOT / "screenshots/appstore" / ("" if folder == "en" else folder)
        ids = [upload(set_id, source / f"{name}.png") for name in SCREENS]
        states = wait_until_processed(ids)
        call(
            "PATCH",
            f"/appScreenshotSets/{set_id}/relationships/appScreenshots",
            {"data": [{"type": "appScreenshots", "id": shot_id} for shot_id in ids]},
        )
        done = sum(state == "COMPLETE" for state in states.values())
        print(f"{folder} ({locale}): uploaded {len(ids)} screenshots, {done} processed")


# Creative assets: header and search results images live in the app's asset library and are
# attached to a localization as "placements".
ASSETS = {
    "PRODUCT_PAGE_HEADER_ASSET": "header-3840x1646.png",
    "APP_STORE_SEARCH_RESULTS_ASSET": "search-results-1920x1280.png",
}


def upload_library_image(file: Path) -> str:
    content = file.read_bytes()
    image = call(
        "POST",
        "/appAssetLibraryImages",
        {
            "data": {
                "type": "appAssetLibraryImages",
                "attributes": {"fileName": file.name, "fileSize": len(content), "category": "CREATIVE_ASSETS"},
                "relationships": {"assetLibrary": {"data": {"type": "appAssetLibraries", "id": APP_ID}}},
            }
        },
    )["data"]
    for operation in image["attributes"]["uploadOperations"]:
        chunk = content[operation["offset"] : operation["offset"] + operation["length"]]
        request = urllib.request.Request(operation["url"], data=chunk, method=operation["method"])
        for header in operation.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        with urllib.request.urlopen(request):
            pass
    call(
        "PATCH",
        f"/appAssetLibraryImages/{image['id']}",
        {"data": {"type": "appAssetLibraryImages", "id": image["id"], "attributes": {"uploaded": True}}},
    )
    # Processing creative assets can take several minutes.
    for _ in range(200):
        attributes = call("GET", f"/appAssetLibraryImages/{image['id']}")["data"]["attributes"]
        if attributes.get("specId"):
            return image["id"]
        if attributes["state"] == "FAILED":
            raise SystemExit(f"{file.name} failed: {attributes.get('stateDetails')}")
        time.sleep(3)
    raise SystemExit(f"{file.name} was not processed in time")


def assets(folders: list[str], replace: bool) -> None:
    version = editable_version()
    locs = localizations(version["id"])
    for folder in folders:
        locale = LOCALES[folder]
        if locale not in locs:
            print(f"{folder}: no {locale} localization")
            continue
        placements = call("GET", f"/appStoreVersionLocalizations/{locs[locale]}/placements?limit=200")["data"]
        for placement_type, file_name in ASSETS.items():
            existing = [p for p in placements if p["attributes"]["placementType"] == placement_type]
            if existing and not replace:
                print(f"{folder}: {placement_type} already set, skipped (use --replace)")
                continue
            for placement in existing:
                call("DELETE", f"/appAssetLibraryPlacements/{placement['id']}")
            source = ROOT / "appstore/marketing" / ("" if folder == "en" else folder) / file_name
            image_id = upload_library_image(source)
            call(
                "POST",
                "/appAssetLibraryPlacements",
                {
                    "data": {
                        "type": "appAssetLibraryPlacements",
                        "attributes": {"placementType": placement_type, "placementGroup": "DEFAULT_PROFILE"},
                        "relationships": {
                            "image": {"data": {"type": "appAssetLibraryImages", "id": image_id}},
                            "appStoreVersionLocalization": {
                                "data": {"type": "appStoreVersionLocalizations", "id": locs[locale]}
                            },
                        },
                    }
                },
            )
            print(f"{folder} ({locale}): {placement_type} set from {file_name}")


def listing(folders: list[str]) -> None:
    """Creates or updates the localized listing from appstore/<folder>/*.txt."""
    app_info = call("GET", f"/apps/{APP_ID}/appInfos")["data"][0]["id"]
    info_locs = {
        item["attributes"]["locale"]: item["id"]
        for item in call("GET", f"/appInfos/{app_info}/appInfoLocalizations?limit=50")["data"]
    }
    version = editable_version()
    for folder in folders:
        locale = LOCALES[folder]
        source = ROOT / "appstore" / ("" if folder == "en" else folder)
        read = lambda name: (source / f"{name}.txt").read_text().strip()  # noqa: E731
        info = {"name": NAME, "subtitle": read("subtitle")}
        if privacy := configured("privacy-policy-url"):
            info["privacyPolicyUrl"] = privacy.format(lang=folder.lower())
        if locale in info_locs:
            call(
                "PATCH",
                f"/appInfoLocalizations/{info_locs[locale]}",
                {"data": {"type": "appInfoLocalizations", "id": info_locs[locale], "attributes": info}},
            )
        else:
            call(
                "POST",
                "/appInfoLocalizations",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "attributes": {"locale": locale, **info},
                        "relationships": {"appInfo": {"data": {"type": "appInfos", "id": app_info}}},
                    }
                },
            )
        attributes = {
            "description": read("description"),
            "keywords": read("keywords"),
            "promotionalText": read("promotional-text"),
        }
        if support := configured("support-url"):
            attributes["supportUrl"] = support.format(lang=folder.lower())
        # Creating the app info localization usually creates the version localization too.
        locs = localizations(version["id"])
        if locale in locs:
            call(
                "PATCH",
                f"/appStoreVersionLocalizations/{locs[locale]}",
                {"data": {"type": "appStoreVersionLocalizations", "id": locs[locale], "attributes": attributes}},
            )
        else:
            call(
                "POST",
                "/appStoreVersionLocalizations",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "attributes": {"locale": locale, **attributes},
                        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}},
                    }
                },
            )
        print(f"{folder} ({locale}): listing saved")


# Age rating questionnaire: Photo Mirror shows only the user's own photos (no web view, chat or ads).
AGE_RATING_NONE = [
    "alcoholTobaccoOrDrugUseOrReferences",
    "contests",
    "gamblingSimulated",
    "gunsOrOtherWeapons",
    "horrorOrFearThemes",
    "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation",
    "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity",
    "sexualContentOrNudity",
    "violenceCartoonOrFantasy",
    "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
]
AGE_RATING_NO = [
    "advertising",
    "ageAssurance",
    "gambling",
    "healthOrWellnessTopics",
    "lootBox",
    "messagingAndChat",
    "parentalControls",
    "socialMedia",
    "unrestrictedWebAccess",
    "userGeneratedContent",
]


def details() -> None:
    app_info = call("GET", f"/apps/{APP_ID}/appInfos")["data"][0]["id"]
    call(
        "PATCH",
        f"/appInfos/{app_info}",
        {
            "data": {
                "type": "appInfos",
                "id": app_info,
                "relationships": {
                    "primaryCategory": {"data": {"type": "appCategories", "id": "PHOTO_AND_VIDEO"}},
                    "secondaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}},
                },
            }
        },
    )
    print("Categories: Photo & Video, Utilities")

    declaration = call("GET", f"/appInfos/{app_info}/ageRatingDeclaration")["data"]
    present = declaration["attributes"]
    answers = {k: "NONE" for k in AGE_RATING_NONE if k in present}
    answers |= {k: False for k in AGE_RATING_NO if k in present}
    call(
        "PATCH",
        f"/ageRatingDeclarations/{declaration['id']}",
        {"data": {"type": "ageRatingDeclarations", "id": declaration["id"], "attributes": answers}},
    )
    print(f"Age rating questionnaire: {len(answers)} answers (none / no)")

    call(
        "PATCH",
        f"/apps/{APP_ID}",
        {
            "data": {
                "type": "apps",
                "id": APP_ID,
                "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"},
            }
        },
    )
    print("Content rights: no third-party content")

    version = editable_version()
    copyright_text = configured("copyright")
    call(
        "PATCH",
        f"/appStoreVersions/{version['id']}",
        {"data": {"type": "appStoreVersions", "id": version["id"], "attributes": {"copyright": copyright_text}}},
    )
    print(f"Copyright: {copyright_text}")

    try:
        has_price = bool(call("GET", f"/appPriceSchedules/{APP_ID}/manualPrices?limit=1").get("data"))
    except SystemExit:  # no price schedule yet
        has_price = False
    if has_price:
        print("Price: already set, left as it is")
        return
    points = call("GET", f"/apps/{APP_ID}/appPricePoints?filter[territory]=USA&limit=10")["data"]
    free = next(p for p in points if float(p["attributes"]["customerPrice"]) == 0)
    call(
        "POST",
        "/appPriceSchedules",
        {
            "data": {
                "type": "appPriceSchedules",
                "relationships": {
                    "app": {"data": {"type": "apps", "id": APP_ID}},
                    "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                    "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]},
                },
            },
            "included": [
                {
                    "type": "appPrices",
                    "id": "${free}",
                    "attributes": {"startDate": None},
                    "relationships": {"appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}},
                }
            ],
        },
    )
    print("Price: free")


def latest_build(version: dict) -> dict:
    """Attaches the newest processed build of this version to it, and returns it."""
    attached = call("GET", f"/appStoreVersions/{version['id']}/build").get("data")
    builds = call(
        "GET",
        f"/builds?filter[app]={APP_ID}&filter[preReleaseVersion.version]={version['attributes']['versionString']}"
        "&filter[processingState]=VALID&filter[expired]=false&sort=-uploadedDate&limit=1",
    )["data"]
    if not builds:
        if attached:
            return attached
        raise SystemExit("No processed build for this version yet.")
    newest = builds[0]
    if not attached or attached["id"] != newest["id"]:
        call(
            "PATCH",
            f"/appStoreVersions/{version['id']}/relationships/build",
            {"data": {"type": "builds", "id": newest["id"]}},
        )
        print(f"Attached build {newest['attributes']['version']} to version {version['attributes']['versionString']}")
    return newest


def submit() -> None:
    version = editable_version()
    build = latest_build(version)
    open_states = {"READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}
    existing = [
        s
        for s in call("GET", f"/reviewSubmissions?filter[app]={APP_ID}&filter[platform]=IOS&limit=20")["data"]
        if s["attributes"]["state"] in open_states
    ]
    # A rejected submission (UNRESOLVED_ISSUES) is resubmitted as it is, like "Resubmit to App Review".
    if existing and existing[0]["attributes"]["state"] not in {"READY_FOR_REVIEW", "UNRESOLVED_ISSUES"}:
        raise SystemExit(f"A submission is already {existing[0]['attributes']['state']}.")
    if existing:
        submission = existing[0]["id"]
    else:
        submission = call(
            "POST",
            "/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
                }
            },
        )["data"]["id"]
        call(
            "POST",
            "/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}},
                    },
                }
            },
        )
    result = call(
        "PATCH",
        f"/reviewSubmissions/{submission}",
        {"data": {"type": "reviewSubmissions", "id": submission, "attributes": {"submitted": True}}},
    )["data"]["attributes"]
    print(
        f"Version {version['attributes']['versionString']} (build {build['attributes']['version']}) "
        f"submitted for review: {result['state']}"
    )


def status() -> None:
    version = editable_version()
    print(f"Version {version['attributes']['versionString']}: {version['attributes']['appStoreState']}")
    for locale, localization_id in sorted(localizations(version["id"]).items()):
        sets = call(
            "GET",
            f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets?include=appScreenshots&limit=20",
        )["data"]
        counts = {s["attributes"]["screenshotDisplayType"]: len(s["relationships"]["appScreenshots"]["data"]) for s in sets}
        placements = call("GET", f"/appStoreVersionLocalizations/{localization_id}/placements?limit=200")["data"]
        creative = sorted(
            {p["attributes"]["placementType"] for p in placements} & set(ASSETS)
        )
        print(f"  {locale:6} {counts or 'no screenshots'}  {', '.join(creative) or 'no header/search images'}")


def next_build() -> None:
    builds = call("GET", f"/builds?filter[app]={APP_ID}&limit=200&fields[builds]=version")["data"]
    print(max((int(b["attributes"]["version"]) for b in builds if b["attributes"]["version"].isdigit()), default=0) + 1)


def wait_build(number: str, minutes: int = 45) -> None:
    deadline = time.time() + minutes * 60
    while time.time() < deadline:
        builds = call("GET", f"/builds?filter[app]={APP_ID}&filter[version]={number}&limit=1")["data"]
        state = builds[0]["attributes"]["processingState"] if builds else "NOT_YET_VISIBLE"
        print(f"Build {number}: {state}", flush=True)
        if state == "VALID":
            return
        if state in {"FAILED", "INVALID"}:
            raise SystemExit(f"Build {number} is {state}.")
        time.sleep(60)
    raise SystemExit(f"Build {number} did not finish processing within {minutes} minutes.")


if __name__ == "__main__":
    command, *args = sys.argv[1:] or ["status"]
    if command == "status":
        status()
    elif command == "assets":
        assets([a for a in args if not a.startswith("--")] or list(LOCALES), replace="--replace" in args)
    elif command == "submit":
        submit()
    elif command == "next-build":
        next_build()
    elif command == "wait-build":
        wait_build(args[0])
    elif command == "listing":
        listing(args or list(LOCALES))
    elif command == "details":
        details()
    elif command == "all":
        listing(list(LOCALES))
        details()
        screenshots(list(LOCALES), replace="--replace" in args)
        assets(list(LOCALES), replace="--replace" in args)
    elif command == "screenshots":
        screenshots([a for a in args if not a.startswith("--")] or list(LOCALES), replace="--replace" in args)
    else:
        raise SystemExit(__doc__)
