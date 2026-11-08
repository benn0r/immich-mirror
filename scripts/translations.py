"""Writes ImmichMirror/Localizable.xcstrings and ImmichMirror/InfoPlist.xcstrings from scripts/l10n/.

`scripts/l10n/source.py` lists the English keys; every language module (`scripts/l10n/<lang>.py`, `-` written
as `_`) defines S (key -> text), P (plural key -> CLDR forms, or one string for languages without plural
forms) and INFO (Info.plist keys). Run `npm run translations` after changing a translation, then build.
New strings (find them with `xcodebuild -exportLocalizations`) must be added to source.py and every language.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
L10N = ROOT / "scripts" / "l10n"
LANGS = [
    "de", "fr", "it", "es", "nl", "pt-PT", "pt-BR", "sv", "da", "nb", "fi", "ja", "pl",
    "zh-Hans", "zh-Hant", "ko", "uk", "cs", "tr",
]  # fmt: skip
DISPLAY_NAME = "Photo Mirror"  # same on every home screen
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(lld|@|%)")


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, L10N / f"{name.replace('-', '_')}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def placeholders(text: str) -> list[str]:
    return sorted(PLACEHOLDER.findall(text))


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms: dict | str) -> dict:
    if isinstance(forms, str):
        forms = {"other": forms}
    return {"variations": {"plural": {category: unit(value) for category, value in forms.items()}}}


def check(lang: str, mod, source) -> list[str]:
    errors = []
    for table, keys in ((mod.S, source.STRINGS), (mod.P, source.PLURALS), (mod.INFO, source.INFO)):
        missing, extra = set(keys) - set(table), set(table) - set(keys)
        errors += [f"{lang}: missing {k!r}" for k in sorted(missing)]
        errors += [f"{lang}: unknown {k!r}" for k in sorted(extra)]
    for key, text in mod.S.items():
        if placeholders(text) != placeholders(key):
            errors.append(f"{lang}: placeholders differ in {key!r}: {text!r}")
    for key, forms in mod.P.items():
        values = [forms] if isinstance(forms, str) else list(forms.values())
        if not isinstance(forms, str) and "other" not in forms:
            errors.append(f"{lang}: plural {key!r} has no 'other' form")
        for text in values:
            if placeholders(text) != placeholders(key):
                errors.append(f"{lang}: placeholders differ in plural {key!r}: {text!r}")
    return errors


def main() -> None:
    source = load("source")
    en = load("en")
    mods = {lang: load(lang) for lang in LANGS}
    errors = [e for lang, mod in mods.items() for e in check(lang, mod, source)]
    errors += [f"en: missing plural {k!r}" for k in source.PLURALS if k not in en.P]
    if errors:
        sys.exit("\n".join(errors))

    strings: dict = {}
    for key in source.STRINGS:
        strings[key] = {"localizations": {lang: unit(mods[lang].S[key]) for lang in LANGS}}
    for key in source.PLURALS:
        loc = {"en": plural(en.P[key])}
        loc.update({lang: plural(mods[lang].P[key]) for lang in LANGS})
        strings[key] = {"localizations": loc}
    for key in source.VERBATIM:
        strings[key] = {"shouldTranslate": False}
    write(ROOT / "ImmichMirror/Localizable.xcstrings", strings)

    info: dict = {
        "CFBundleDisplayName": {"shouldTranslate": False},
        "CFBundleName": {"shouldTranslate": False},
    }
    for key in source.INFO:
        info[key] = {"localizations": {lang: unit(mods[lang].INFO[key]) for lang in LANGS}}
    write(ROOT / "ImmichMirror/InfoPlist.xcstrings", info)
    print(f"{len(strings)} strings, {len(info)} Info.plist keys, {len(LANGS)} languages + English")


def write(path: Path, strings: dict) -> None:
    data = {"sourceLanguage": "en", "strings": dict(sorted(strings.items())), "version": "1.0"}
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n")


if __name__ == "__main__":
    main()
