#!/usr/bin/env python3
"""Select an immutable, published app release for the Pages workflow."""

import base64
import json
import os
import re
import subprocess
from pathlib import Path
from urllib.parse import quote

TAG = re.compile(r"v\d+\.\d+\.\d+\+\d+")


def select_release(event_name, event, repository, api):
    automatic = event_name != "workflow_dispatch"
    run = None
    if event_name == "workflow_run":
        run = event["workflow_run"]
        if (
            run["conclusion"] != "success"
            or run["event"] != "push"
            or run["head_branch"] != "release"
            or run["head_repository"]["full_name"] != repository
        ):
            raise ValueError("Only successful release builds from this repository qualify")
        source = api(f"contents/pubspec.yaml?ref={run['head_sha']}")
        pubspec = base64.b64decode(source["content"]).decode()
        version = re.search(r"^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$", pubspec, re.M)
        if version is None:
            raise ValueError("The completed build has no release version")
        tag = "v" + version[1]
    elif event_name == "release":
        if event["release"]["draft"] or event["release"]["prerelease"]:
            return None
        tag = event["release"]["tag_name"]
    elif event_name == "workflow_dispatch":
        tag = event.get("inputs", {}).get("release_tag", "").strip()
    else:
        raise ValueError("Unsupported deployment event")

    latest = api("releases/latest")
    tag = tag or latest["tag_name"]
    if TAG.fullmatch(tag) is None:
        raise ValueError("Expected an app release tag such as v2.4.0+600")
    # A delayed old build/release event must not roll production backwards.
    if automatic and tag != latest["tag_name"]:
        return None
    release = latest if tag == latest["tag_name"] else api(f"releases/tags/{quote(tag, safe='')}")
    if release["draft"] or release["prerelease"] or release["tag_name"] != tag:
        raise ValueError("A published stable release is required")
    sha = api(f"commits/{quote(tag, safe='')}")["sha"]
    if re.fullmatch(r"[0-9a-f]{40}", sha) is None:
        raise ValueError("Invalid release commit")
    if run is not None and run["head_sha"] != sha:
        return None
    return {"tag": tag, "sha": sha, "version": tag[1:]}


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    if re.fullmatch(r"[\w.-]+/[\w.-]+", repository) is None:
        raise ValueError("Invalid repository")

    def api(path):
        result = subprocess.run(
            ["gh", "api", f"repos/{repository}/{path}"],
            check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)

    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    selected = select_release(os.environ["GITHUB_EVENT_NAME"], event, repository, api)
    print(f"deploy={'true' if selected else 'false'}")
    for key, value in (selected or {}).items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
