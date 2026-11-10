load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "AyuGramUI",
    module_name = "AyuGramUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AccountContext:AccountContext",
        "//submodules/AppBundle:AppBundle",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/LegacyComponents:LegacyComponents",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/MergeLists:MergeLists",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        # AYGChatPreviewItem only: the timestamp formatter and the wallpaper the
        # preview bubbles sit on. Neither module reaches AyuGramUI transitively, so
        # neither closes a cycle — check that again before adding anything here.
        "//submodules/TextFormat:TextFormat",
        "//submodules/WallpaperBackgroundNode:WallpaperBackgroundNode",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
