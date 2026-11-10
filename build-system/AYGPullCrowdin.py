#!/usr/bin/env python3
"""AYG: pull AyuGram's translations from Crowdin, the way AyuGram itself does.

AyuGram's strings live in a Crowdin project; the Android build ships the exported
`values-<lang>/ayu.xml` files as assets. This script is our half of that pipeline: it
asks Crowdin to build a fresh export, downloads it, and drops the per-language XML
into `docs/AYGLocales/`. Run `AYGCompileLocales.py` afterwards to turn those into the
JSON the app bundles.

    export AYG_CROWDIN_TOKEN=...        # a personal access token
    export AYG_CROWDIN_PROJECT_ID=...   # the numeric project id
    python3 build-system/AYGPullCrowdin.py

**Credentials are the catch.** The API only serves projects the token can see, so this
needs access to AyuGram's own Crowdin project — an AyuGram maintainer's token, or your
own project if you fork the translations. Without it the script refuses rather than
half-working; the files currently in `docs/AYGLocales/` were taken from the APK, which
is the published output of exactly this export, so the tree is not blocked on it.
"""

import io
import json
import os
import sys
import time
import urllib.request
import zipfile

API = "https://api.crowdin.com/api/v2"
DESTINATION = "docs/AYGLocales"

# Crowdin's locale ids to the codes this repo files translations under. Only the ones
# that differ from a plain lowercase language code need an entry.
LANGUAGE_CODES = {
    "zh-CN": "zh-CN",
    "zh-TW": "zh-TW",
    "he": "he",
    "pt-BR": "pt",
}


def request(path, token, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read())


def main():
    token = os.environ.get("AYG_CROWDIN_TOKEN")
    project = os.environ.get("AYG_CROWDIN_PROJECT_ID")
    if not token or not project:
        print(
            "AYG_CROWDIN_TOKEN and AYG_CROWDIN_PROJECT_ID must both be set.\n"
            "See the module docstring: this needs access to AyuGram's Crowdin project.",
            file=sys.stderr,
        )
        return 2

    print("requesting a build…")
    build = request(f"/projects/{project}/translations/builds", token, method="POST", body={})
    build_id = build["data"]["id"]

    while True:
        status = request(f"/projects/{project}/translations/builds/{build_id}", token)
        state = status["data"]["status"]
        print(f"  build {build_id}: {state}")
        if state == "finished":
            break
        if state in ("failed", "canceled"):
            print("build did not finish", file=sys.stderr)
            return 1
        time.sleep(3)

    download = request(f"/projects/{project}/translations/builds/{build_id}/download", token)
    url = download["data"]["url"]

    print("downloading…")
    with urllib.request.urlopen(url) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))

    os.makedirs(DESTINATION, exist_ok=True)
    written = 0
    for name in archive.namelist():
        if not name.endswith(".xml"):
            continue
        # Crowdin lays the export out per language; the last directory component is
        # the locale.
        parts = [p for p in name.split("/") if p]
        if len(parts) < 2:
            continue
        locale = parts[-2]
        code = LANGUAGE_CODES.get(locale, locale.split("-")[0])
        with open(os.path.join(DESTINATION, code + ".xml"), "wb") as handle:
            handle.write(archive.read(name))
        written += 1
        print(f"  {code}")

    print(f"--- {written} files -> {DESTINATION}")
    print("now run: python3 build-system/AYGCompileLocales.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
