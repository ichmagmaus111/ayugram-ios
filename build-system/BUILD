
config_setting(
	name = "ios_sim_arm64",
	values = {"cpu": "ios_sim_arm64"},
)

config_setting(
    name = "linux_arm64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:aarch64",
    ],
)

config_setting(
    name = "linux_x86_64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:x86_64",
    ],
)

exports_files([
    "GenerateStrings/GenerateStrings.py",
    # XTG: the Telegram → brand string rename, run by a genrule in Telegram/BUILD.
    "XTGRenameStrings.py",
])
