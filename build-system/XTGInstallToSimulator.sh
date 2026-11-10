#!/bin/bash
# XTG: install the freshly built app onto a simulator, keeping the login.
#
#   Usage: build-system/XTGInstallToSimulator.sh [device-udid-or-name]
#          defaults to the currently booted simulator.
#
# The bundle is ayugram.app — see build-system/xtg_flavor.bzl. It is unpacked from bazel-bin/Telegram/Telegram.ipa,
# which bazel rewrites on every build and points at the last build's configuration.
# Not from Telegram_archive-root/ any more (13.0 port): upstream found that the
# post-build packaging leaves that directory alone on a cache-hit incremental build,
# so it can hold a PREVIOUS build's binaries with nothing (mtime, name) showing it.
# Dev builds use the bundle id ph.telegra.Telegraph (the fake-codesigning profiles
# are issued for it).
#
# What actually matters here, measured on Xcode 26.6 / iOS 26.2:
#
#   * `simctl uninstall` DELETES the data container — that is what makes you log in
#     again. Never use it just to pick up a rebuild.
#   * `simctl install` KEEPS your data. It moves the data container to a new UUID
#     path but carries the contents across, and it is the only way Info.plist
#     changes (display name, icons, permissions text) reach SpringBoard/installd.
#   * Replacing the .app in place keeps the data container path AND the contents,
#     but installd never re-reads Info.plist, so metadata changes silently do not
#     show up. It is also the documented workaround for installd's hard-link cache
#     skipping an install when the build number has not changed.
#
# So: install normally, then verify the installed binary really is the fresh one,
# and only fall back to the in-place swap if it is not.

set -euo pipefail

BUNDLE_ID="ph.telegra.Telegraph"
DEVICE="${1:-}"

if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun simctl list devices booted -j \
        | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; a=[x for v in d.values() for x in v]; print(a[0]["udid"] if a else "")')"
    [ -n "$DEVICE" ] || { echo "No booted simulator, and none given. Boot one or pass a udid."; exit 1; }
fi

cd "$(dirname "$0")/.."

IPA="bazel-bin/Telegram/Telegram.ipa"
[ -f "$IPA" ] || { echo "No $IPA — build first."; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
unzip -q -o "$IPA" -d "$STAGE"
SRC="$(find "$STAGE/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
APP_NAME="$(basename "${SRC:-none.app}" .app)"
[ -n "$SRC" ] && [ -x "$SRC/$APP_NAME" ] || {
    echo "No .app inside $IPA — build first."; exit 1; }

echo "device : $DEVICE"
echo "app    : $APP_NAME.app"
echo "source : $SRC"

xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$SRC"

DEST="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" app)"
WANT="$(shasum -a 256 "$SRC/$APP_NAME" | awk '{print $1}')"
GOT="$(shasum -a 256 "$DEST/$APP_NAME" | awk '{print $1}')"

if [ "$WANT" != "$GOT" ]; then
    # installd kept a cached copy (same build number). Swap the bundle by hand.
    # Guarded on SRC above, so a failed copy cannot leave the device with no app.
    echo "installd served a stale binary — replacing the bundle in place"
    xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
    rm -rf "$DEST"
    cp -Rp "$SRC" "$DEST"
    echo "note: Info.plist changes (display name, icons) will NOT show until an install"
    echo "      that installd accepts — bump --buildNumber if you need them picked up."
else
    echo "installed binary matches the build"
fi

echo "data   : $(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
