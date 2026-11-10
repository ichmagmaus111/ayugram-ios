#!/usr/bin/env python3
# XTG: rename only the strings where "Telegram" means *this app on this device*.
# Anything about the Telegram service, network, servers, accounts, company,
# legal terms or products (Premium / Stars / Passport / Ads / Business / Gifts)
# is left alone — those statements are Telegram's, not the fork's.
#
# Runs at build time from a genrule in Telegram/BUILD:
#
#     XTGRenameStrings.py --brand AyuGram --input en.lproj/Localizable.strings --output <out>
#     XTGRenameStrings.py --brand AyuGram    --input en.lproj/InfoPlist.strings   --output <out>
#
# The tree keeps upstream's untouched files; the brand is the app's
# (`xtg_brand_name` in build-system/xtg_flavor.bzl). Idempotent: an already
# renamed input comes out unchanged. The four InfoPlist.strings keys at the end of
# the list are the permission descriptions Telegram/BUILD also carries inline.
import argparse, io, re, sys

KEYS = """
Tour.Title1 Tour.Text2 Tour.Text3 Tour.Text4 Tour.Text5 Tour.Text6
Contacts.AccessDeniedError Contacts.AccessDeniedHelpLandscape Contacts.AccessDeniedHelpPortrait
Contacts.PermissionsText Contacts.LimitedAccess.Text
AccessDenied.Contacts AccessDenied.VoiceMicrophone AccessDenied.VideoMicrophone
AccessDenied.MicrophoneRestricted AccessDenied.Camera AccessDenied.CameraRestricted
AccessDenied.PhotosAndVideos AccessDenied.SaveMedia AccessDenied.PhotosRestricted
AccessDenied.LocationDenied AccessDenied.LocationDisabled AccessDenied.LocationTracking
AccessDenied.CallMicrophone AccessDenied.VideoMessageCamera AccessDenied.VideoMessageMicrophone
AccessDenied.LocationAlwaysDenied AccessDenied.Wallpapers AccessDenied.VideoCallCamera
AccessDenied.QrCode AccessDenied.QrCamera AccessDenied.LocationPreciseDenied
AccessDenied.LocationWeather AccessDenied.AgeVerificationCamera
InfoPlist.NSContactsUsageDescription InfoPlist.NSLocationWhenInUseUsageDescription
InfoPlist.NSLocationAlwaysAndWhenInUseUsageDescription InfoPlist.NSLocationAlwaysUsageDescription
PasscodeSettings.EncryptDataHelp EnterPasscode.EnterTitle EnterPasscode.EnterPasscode
EnterPasscode.TouchId DialogList.PasscodeLockHelp Passcode.AppLockedAlert
Cache.Indexing ClearCache.StorageCache ClearCache.StorageServiceFiles ClearCache.ClearCache
StorageManagement.DescriptionChatUsage StorageManagement.DescriptionAppUsage
Watch.AppName Watch.Location.Access Watch.Microphone.Access Watch.AuthRequired
Widget.AuthRequired Widget.GalleryTitle Application.Name
Update.Title Update.AppVersion Update.UpdateApp
Share.AuthTitle Share.AuthDescription ShareFileTip.Text Conversation.FileHowToText
AppUpgrade.Running Media.LimitedAccessText
Attachment.LimitedMediaAccessText Attachment.CameraAccessText
ChatImportActivity.OpenApp Intents.ErrorLockedText Story.Camera.AccessPlaceholderTitle
PowerSavingScreen.OptionAutoplayEffectsText Map.HomeAndWorkInfo
Permissions.CellularDataText.v0 Notifications.PermissionsSuppressWarningText
Calls.RatingTitle Call.StatusIncoming Call.StatusOngoing Call.PhoneCallInProgressMessage
UserInfo.TelegramCall UserInfo.TelegramVideoCall
Chat.Context.Phone.TelegramVoiceCall Chat.Context.Phone.TelegramVideoCall
Privacy.Calls.IntegrationHelp
WebBrowser.Telegram WebBrowser.OpenLinksInfo WebBrowser.ClearCookies.Info
Login.ErrorAppOutdated Story.UnsupportedText Story.UnsupportedAction
Conversation.UnsupportedMedia Conversation.UnsupportedMediaPlaceholder Conversation.UpdateTelegram
Conversation.UnsupportedMedia.Text PasscodeSettings.LockTelegram
Passport.UpdateRequiredError Gift.Transfer.UpdateRequired.Text
Notifications.TelegramTones Notifications.UploadSuccess.Text
NSContactsUsageDescription NSLocationWhenInUseUsageDescription
NSLocationAlwaysAndWhenInUseUsageDescription NSLocationAlwaysUsageDescription
""".split()
KEYS = set(KEYS)

parser = argparse.ArgumentParser(description="Rename Telegram -> <brand> in the strings that name this app.")
parser.add_argument("--brand", required=True, help="the app's name, e.g. AyuGram")
parser.add_argument("--input", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--quiet", action="store_true")
args = parser.parse_args()

brand = args.brand
text = io.open(args.input, encoding="utf-8").read()

# Whole-entry matching rather than line matching: a value may span physical lines
# (`AppUpgrade.Running` does), and the all-caps `TELEGRAM` variants would slip
# through a guard that only looks for `Telegram`.
entry_re = re.compile(r'("((?:[^"\\]|\\.)+)"\s*=\s*")((?:[^"\\]|\\.|\n)*?)(";)', re.S)

changed, seen = [], set()
def rewrite(m):
    key, value = m.group(2), m.group(3)
    if key not in KEYS or ("Telegram" not in value and "TELEGRAM" not in value):
        return m.group(0)
    seen.add(key)
    # capital-T only: telegram.org / t.me URLs are lowercase and stay intact
    new_value = value.replace("TELEGRAM", brand.upper()).replace("Telegram", brand)
    # "a Telegram call" must become "an AyuGram call": fix the article for a brand
    # that starts with a vowel (the AyuGram fork did this by hand).
    if brand[:1].lower() in "aeiou":
        new_value = re.sub(r"\b([Aa]) " + re.escape(brand) + r"\b", lambda m: m.group(1) + "n " + brand, new_value)
    changed.append((key, value, new_value))
    return m.group(1) + new_value + m.group(4)

io.open(args.output, "w", encoding="utf-8").write(entry_re.sub(rewrite, text))
if not args.quiet:
    print(f"{args.input}: entries rewritten: {len(changed)}   distinct keys hit: {len(seen)}", file=sys.stderr)
