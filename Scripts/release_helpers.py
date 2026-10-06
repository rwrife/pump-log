#!/usr/bin/env python3
"""Release-only helpers. No app runtime networking or secret logging."""
import argparse
import json
import os
import plistlib
from pathlib import Path

BUNDLE_ID = "com.infinityball.pumplog"


def write_key(directory: Path) -> Path:
    for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8", "ASC_TEAM_ID"):
        if not os.environ.get(name, "").strip():
            raise ValueError(f"Missing repository secret: {name}")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    path = directory / "AuthKey.p8"
    key = os.environ["ASC_KEY_P8"].replace("\\n", "\n").strip() + "\n"
    if not key.startswith("-----BEGIN PRIVATE KEY-----") or "-----END PRIVATE KEY-----" not in key:
        raise ValueError("ASC_KEY_P8 is not a PEM private key")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(key)
    return path


def export_options(team: str, upload: bool) -> dict:
    if not team.strip():
        raise ValueError("Missing repository secret: ASC_TEAM_ID")
    options = {"method": "app-store-connect", "signingStyle": "automatic",
               "teamID": team, "manageAppVersionAndBuildNumber": False,
               "uploadSymbols": True, "destination": "upload" if upload else "export"}
    if upload:
        options["uploadMethod"] = "app-store-connect"
    return options


def verify_archive(app: Path, build_number: str) -> dict:
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    expected = {"CFBundleIdentifier": BUNDLE_ID, "UIDeviceFamily": [1],
                "CFBundleVersion": build_number, "DTSDKName": "iphoneos26.0",
                "DTXcodeBuild": "17A400"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"Archive {key} must be {value!r}; observed {info.get(key)!r}")
    if not (app / "Assets.car").is_file() or not list(app.glob("AppIcon*.png")):
        raise ValueError("Archive has no compiled app icon evidence")
    return {key: info[key] for key in expected} | {
        "marketing_version": info["CFBundleShortVersionString"]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("key", "options", "verify"))
    parser.add_argument("path", type=Path)
    parser.add_argument("--upload", choices=("true", "false"), default="false")
    args = parser.parse_args()
    if args.action == "key":
        write_key(args.path)
        print("ASC key materialized with mode 600 (contents not logged)")
    elif args.action == "options":
        args.path.write_bytes(plistlib.dumps(export_options(os.environ.get("ASC_TEAM_ID", ""), args.upload == "true")))
    else:
        evidence = verify_archive(args.path, os.environ["GITHUB_RUN_NUMBER"])
        Path("build/release/archive-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    main()
