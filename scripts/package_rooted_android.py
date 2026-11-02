#!/usr/bin/env python3
"""Package the full privileged app for systemless installation."""

import argparse
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP_PATH = "system/priv-app/ee.nekoko.nlpa2/NekokoLPA.apk"
PERMISSION_PATH = "system/etc/permissions/privapp-permissions-ee.nekoko.nlpa2.xml"


def package(apk, output, version, template=ROOT / "magisk_template"):
    match = re.fullmatch(r"(\d+\.\d+\.\d+)\+(\d+)", version)
    if match is None:
        raise ValueError("Expected an app version such as 2.4.0+600")
    if not zipfile.is_zipfile(apk):
        raise ValueError("A built APK is required")
    with zipfile.ZipFile(apk) as source:
        if "AndroidManifest.xml" not in source.namelist():
            raise ValueError("APK has no AndroidManifest.xml")
    prop = (template / "module.prop").read_text()
    prop = re.sub(r"^version=.*$", f"version=v{match[1]}", prop, flags=re.M)
    prop = re.sub(r"^versionCode=.*$", f"versionCode={match[2]}", prop, flags=re.M)
    files = {
        "module.prop": prop.encode(),
        "customize.sh": (template / "customize.sh").read_bytes(),
        PERMISSION_PATH: (template / "privapp-permissions-ee.nekoko.nlpa2.xml").read_bytes(),
        APP_PATH: Path(apk).read_bytes(),
    }
    for source in (template / "META-INF").rglob("*"):
        if source.is_file():
            files[source.relative_to(template).as_posix()] = source.read_bytes()
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path, data in sorted(files.items()):
            entry = zipfile.ZipInfo(path)
            executable = path == "customize.sh" or path.endswith("/update-binary")
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    print(package(args.apk, args.output, args.version))


if __name__ == "__main__":
    main()
