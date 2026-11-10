#!/bin/bash
# XTG: build a release-signed IPA, with progress visible while it runs.
#
#   Usage: build-system/XTGBuildRelease.sh ayu adhoc|appstore [extra Make.py args...]
#
# The identity — configuration (bundle id, api pair) and profiles:
#
#   ayu        build-system/AYG{AdHoc,AppStore}Configuration.json
#              build-input/codesigning-{adhoc,appstore}-ayugram/    (AyuGram, same team)
#
# adhoc    — signed with the Ad Hoc profiles, installs straight onto a device
#            registered on the team. The one to use for on-device testing.
# appstore — signed for App Store submission. Cannot be installed directly;
#            it only goes up through TestFlight / App Store Connect.
#
# Both use the team's distribution certificate whose private key is in the login
# keychain, and the profiles under the directories above (profiles/*.mobileprovision
# + certs/Distribution.cer). Those directories and the configurations are gitignored:
# they are the app's identity, not source.
#
# Do NOT pipe this through grep to "keep it quiet" — that hides bazel's
# `[N / TOTAL] <action>` progress line, which is the only way to see where a
# 20-minute build actually is. The full output goes to the log named below.

set -uo pipefail
cd "$(dirname "$0")/.."

FLAVOR="${1:-}"
VARIANT="${2:-}"
case "$FLAVOR" in
    ayu)      PREFIX="AYG"; SUFFIX="-ayugram" ;;
    *)
        echo "usage: $0 ayu adhoc|appstore [extra Make.py args...]" >&2
        exit 2
        ;;
esac
case "$VARIANT" in
    adhoc)
        CONFIG="build-system/${PREFIX}AdHocConfiguration.json"
        CODESIGNING="build-input/codesigning-adhoc${SUFFIX}"
        ;;
    appstore)
        CONFIG="build-system/${PREFIX}AppStoreConfiguration.json"
        CODESIGNING="build-input/codesigning-appstore${SUFFIX}"
        ;;
    *)
        echo "usage: $0 ayu adhoc|appstore [extra Make.py args...]" >&2
        exit 2
        ;;
esac
shift 2

[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG is missing." >&2; exit 1; }
[ -d "$CODESIGNING/profiles" ] || { echo "ERROR: $CODESIGNING/profiles is missing — generate the provisioning profiles first." >&2; exit 1; }

if grep -q "REPLACE_WITH_OWN_API" "$CONFIG"; then
    echo "ERROR: $CONFIG still carries placeholder api_id/api_hash." >&2
    echo "       Register the fork's own pair on my.telegram.org before building for a device:" >&2
    echo "       Telegram's public test pair (api_id 8) gets real accounts banned." >&2
    exit 1
fi

LOG="${XTG_BUILD_LOG:-/tmp/xtg-build-release-$FLAVOR-$VARIANT.log}"
BUILD_NUMBER="${XTG_BUILD_NUMBER:-1}"

echo "flavor     : $FLAVOR"
echo "variant    : $VARIANT"
echo "config     : $CONFIG"
echo "codesigning: $CODESIGNING"
echo "build no.  : $BUILD_NUMBER"
echo "log        : $LOG"
BAZEL_LOG="$(ls -t /private/var/tmp/_bazel_"$(whoami)"/*/command.log 2>/dev/null | head -1)"
[ -n "$BAZEL_LOG" ] && echo "bazel log  : $BAZEL_LOG"
echo

# XTG: pin bazel to the xcode-select'ed Xcode (see XTGXcodeConfig.sh).
build-system/XTGXcodeConfig.sh || exit 1

python3 build-system/Make/Make.py --overrideXcodeVersion \
    --cacheDir ~/telegram-bazel-cache \
    build \
    --configurationPath "$CONFIG" \
    --codesigningInformationPath "$CODESIGNING" \
    --flavor "$FLAVOR" \
    --buildNumber="$BUILD_NUMBER" --configuration=release_arm64 \
    "$@" 2>&1 | tee "$LOG"

# bash (shebang): PIPESTATUS is 0-indexed, so [0] is Make.py's own status.
status=${PIPESTATUS[0]}
echo
if [ "$status" = "0" ]; then
    echo "BUILD OK ($FLAVOR $VARIANT) — bazel-bin/Telegram/Telegram.ipa"
else
    echo "BUILD FAILED ($FLAVOR $VARIANT, exit $status) — errors:"
    grep -E "^ERROR:|error: " "$LOG" | head -20
fi
exit "$status"
