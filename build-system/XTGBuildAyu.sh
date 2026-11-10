#!/bin/bash
# XTG: build AyuGram, under AyuGram's identity.
#
#   build-system/XTGBuildAyu.sh                    simulator build  (XTGBuild.sh ayu)
#   build-system/XTGBuildAyu.sh adhoc|appstore     release IPA      (XTGBuildRelease.sh ayu ...)
#
# Anything after the variant is passed on to Make.py (e.g. --continueOnError).
set -u
cd "$(dirname "$0")/.."
case "${1:-}" in
    adhoc|appstore)
        VARIANT="$1"
        shift
        exec build-system/XTGBuildRelease.sh ayu "$VARIANT" "$@"
        ;;
    *)
        exec build-system/XTGBuild.sh ayu "$@"
        ;;
esac
