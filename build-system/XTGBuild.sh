#!/bin/bash
# XTG: build the app for the simulator, with progress visible while it runs.
#
#   Usage: build-system/XTGBuild.sh ayu [extra Make.py args...]
#
#   ayu      AyuGram, under AyuGram's identity   AYGDevelopmentConfiguration.json
#
# `--flavor` reaches Make.py, which writes it into variables.bzl (name, icons, bundled
# assets — build-system/xtg_flavor.bzl) and turns it into the Swift compilation
# condition AYUGRAM. XTGBuildAyu.sh calls this one (or XTGBuildRelease.sh for
# adhoc / appstore).
#
# Do NOT pipe this through grep to "keep it quiet" — that hides bazel's
# `[N / TOTAL] <action>` progress line, which is the only way to see where a
# 20-minute build actually is. The full output goes to the log named below, and
# bazel additionally keeps its own copy at <output_base>/command.log, which is
# what a progress watcher should tail.

set -uo pipefail
cd "$(dirname "$0")/.."

FLAVOR="${1:-}"
case "$FLAVOR" in
    ayu)      CONFIG="build-system/AYGDevelopmentConfiguration.json" ;;
    *)
        echo "usage: $0 ayu [extra Make.py args...]" >&2
        exit 2
        ;;
esac
shift

[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG is missing (it is gitignored — copy it from the fork that owns it)." >&2; exit 1; }

LOG="${XTG_BUILD_LOG:-/tmp/xtg-build-$FLAVOR.log}"

echo "flavor     : $FLAVOR"
echo "config     : $CONFIG"
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
    --codesigningInformationPath build-system/fake-codesigning \
    --flavor "$FLAVOR" \
    --buildNumber=1 --configuration=debug_sim_arm64 \
    "$@" 2>&1 | tee "$LOG"

# The script runs under bash (shebang): PIPESTATUS is 0-indexed, so [0] is
# Make.py's own exit status. (AyuGram's copy read [1] — tee, which is always 0,
# so its "BUILD OK" line never reflected a failure.)
status=${PIPESTATUS[0]}
echo
if [ "$status" = "0" ]; then
    echo "BUILD OK ($FLAVOR)"
else
    echo "BUILD FAILED ($FLAVOR, exit $status) — errors:"
    grep -E "^ERROR:|error: " "$LOG" | head -20
fi
exit "$status"
