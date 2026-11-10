# XTG: the build flavor, derived once from the value Make.py writes into
# `@build_configuration//:variables.bzl`, for every BUILD file that has to choose
# brand assets or names at load time. This tree builds one client, AyuGram:
#
#     ayu      AyuGram, under AyuGram's identity
#
# "Identity" means bundle id, api pair, provisioning profiles, app name, icons and
# the Telegram -> brand string rename.

load("@build_configuration//:variables.bzl", _xtg_flavor = "xtg_flavor")

XTG_FLAVORS = ["ayu"]

def _check_flavor():
    if _xtg_flavor not in XTG_FLAVORS:
        fail("xtg_flavor must be one of {}, got {}".format(XTG_FLAVORS, repr(_xtg_flavor)))

_check_flavor()

xtg_flavor = _xtg_flavor

# User-visible name of the app: what every "Telegram" that means *this app*
# becomes, in Info.plist and in the renamed strings.
xtg_brand_name = "AyuGram"

# Name of the `.app` bundle and of its executable.
xtg_brand_bundle_name = "ayugram"

# Prefix of the brand's asset names: <prefix>AppIcon.icon (primary icon),
# <prefix>Icon.alticon (the single picker entry) and <prefix>IntroLogo.imageset.
xtg_brand_asset_prefix = "AYG"
