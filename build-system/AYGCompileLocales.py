#!/usr/bin/env python3
"""AYG: turn the Crowdin-exported Android locale files into per-language JSON.

AyuGram keeps its translations on Crowdin, exports them as
`assets/ayu_locales/values-<lang>/ayu.xml` and bundles those into the APK — there is
no runtime translation API. This is the same step for us: `docs/AYGLocales/*.xml` in,
`Telegram/Telegram-iOS/AYGLocales/*.json` out, one file per language so the app only
ever parses the one it needs (plus English as the fallback).

    python3 build-system/AYGCompileLocales.py

Re-run it after `AYGPullCrowdin.py` brings new translations down.
"""

import html
import json
import os
import re
import sys

SOURCE = "docs/AYGLocales"
DESTINATION = "Telegram/Telegram-iOS/AYGLocales"

# Android escapes these inside `<string>`; iOS wants the literal character.
ANDROID_ESCAPES = [
    (r"\\'", "'"),
    (r'\\"', '"'),
    (r"\\n", "\n"),
    (r"\\t", "\t"),
    (r"\\@", "@"),
]


def parse(path):
    text = open(path, encoding="utf-8").read()
    strings = {}
    for match in re.finditer(r'<string name="([^"]+)">(.*?)</string>', text, re.S):
        key, value = match.group(1), match.group(2)
        value = html.unescape(value)
        for pattern, replacement in ANDROID_ESCAPES:
            value = re.sub(pattern, replacement, value)
        # Android's positional format specifiers are `%1$s`; iOS uses `%1$@` for a
        # string. Left alone here — no AYG string is formatted at runtime yet, and a
        # blind rewrite would corrupt the numeric ones.
        strings[key] = value
    return strings


def main():
    os.makedirs(DESTINATION, exist_ok=True)
    written = 0
    for name in sorted(os.listdir(SOURCE)):
        if not name.endswith(".xml"):
            continue
        language = name[: -len(".xml")]
        strings = parse(os.path.join(SOURCE, name))
        if not strings:
            print(f"skipped {language}: no strings", file=sys.stderr)
            continue
        out = os.path.join(DESTINATION, language + ".json")
        with open(out, "w", encoding="utf-8") as handle:
            json.dump(strings, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        written += 1
        print(f"{language:8} {len(strings):4} strings")
    print(f"--- {written} locales -> {DESTINATION}")


if __name__ == "__main__":
    main()
