#!/usr/bin/env python3
"""eye/index.json — the signed manifest ClusterEye OS servers trust.

ClusterEye OS reads this file (and its detached signature eye/index.json.asc,
made with the ClusterEye release key) for two things:

  eye_os_releases          the OS images and in-place upgrade bundles
                           (eye-upgrade check/download on the server)
  clustereye_api_releases  the API binary and the UI tarball an operator can
  clustereye_ui_releases   move a server to (eye-component list/download)

The OS list is written by update-eye-os.yml. The two component lists are
NEVER edited by hand or by a workflow: they are rebuilt from what is really
under downloads/api and downloads/ui (each version directory's .sha256
sidecars), at every Pages deploy, so the index can never point at a version
the prune removed or miss one a mirror added.

Usage:
  eye-index.py upsert-os <entry.json>   add or replace one eye_os_releases entry
  eye-index.py sync-components          rebuild the API/UI lists from downloads/
  eye-index.py check                    exit 1 unless the index is well-formed

Version order everywhere: newest first by semantic version (v1.6.14 above
v1.6.9), never by string.
"""
import json
import os
import re
import sys

INDEX = "eye/index.json"
DOMAIN_BASE = "https://archive.clustereye.com"
SHA = re.compile(r"^[0-9a-f]{64}$")
VER = re.compile(r"^v\d+\.\d+\.\d+$")


def version_key(version):
    v = str(version or "").lstrip("vV")
    core, _, suffix = v.partition("-")
    parts = core.split(".")
    if not parts or not all(p.isdigit() for p in parts):
        return (0, (), 0, v)
    return (1, tuple(int(p) for p in parts), 0 if suffix else 1, suffix)


def load():
    try:
        with open(INDEX) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"eye_os_releases": [], "clustereye_api_releases": [], "clustereye_ui_releases": []}


def dump(index):
    os.makedirs(os.path.dirname(INDEX), exist_ok=True)
    for key in ("eye_os_releases", "clustereye_api_releases", "clustereye_ui_releases"):
        index.setdefault(key, []).sort(key=lambda e: version_key(e.get("version")), reverse=True)
    with open(INDEX, "w") as f:
        json.dump(index, f, indent=2)
        f.write("\n")


def sidecar(path):
    """The checksum in a `sha256sum` sidecar file, or None."""
    try:
        with open(path) as f:
            word = f.read().split()[0]
    except (OSError, IndexError):
        return None
    return word if SHA.match(word) else None


def sync_components(index):
    api, ui = [], []
    for name in sorted(os.listdir("downloads/api")) if os.path.isdir("downloads/api") else []:
        d = f"downloads/api/{name}"
        if not VER.match(name) or not os.path.isfile(f"{d}/clustereye-api.gz"):
            continue
        gz, raw = sidecar(f"{d}/clustereye-api.gz.sha256"), sidecar(f"{d}/clustereye-api.sha256")
        if not gz or not raw:
            sys.exit(f"{d}: clustereye-api.gz.sha256 or clustereye-api.sha256 is missing or malformed")
        api.append({"version": name, "files": [{
            "name": "clustereye-api.gz", "arch": "linux-amd64",
            "download_url": f"{DOMAIN_BASE}/{d}/clustereye-api.gz",
            "sha256": gz, "sha256_uncompressed": raw}]})
    for name in sorted(os.listdir("downloads/ui")) if os.path.isdir("downloads/ui") else []:
        d = f"downloads/ui/{name}"
        if not VER.match(name) or not os.path.isfile(f"{d}/clustereye.tar.gz"):
            continue
        s = sidecar(f"{d}/clustereye.tar.gz.sha256")
        if not s:
            sys.exit(f"{d}: clustereye.tar.gz.sha256 is missing or malformed")
        ui.append({"version": name, "files": [{
            "name": "clustereye.tar.gz",
            "download_url": f"{DOMAIN_BASE}/{d}/clustereye.tar.gz", "sha256": s}]})
    index["clustereye_api_releases"], index["clustereye_ui_releases"] = api, ui
    print(f"{INDEX}: api {[e['version'] for e in api]}, ui {[e['version'] for e in ui]}")


def upsert_os(index, entry):
    v = entry.get("version", "")
    if not VER.match(v):
        sys.exit(f"eye_os entry: implausible version {v!r}")
    lst = index.setdefault("eye_os_releases", [])
    lst[:] = [e for e in lst if e.get("version") != v] + [entry]
    print(f"{INDEX}: eye_os_releases ← {v}")


def check(index):
    problems = []
    for key in ("eye_os_releases", "clustereye_api_releases", "clustereye_ui_releases"):
        lst = index.get(key)
        if not isinstance(lst, list):
            problems.append(f"{key}: missing")
            continue
        versions = [e.get("version") for e in lst]
        if len(set(versions)) != len(versions):
            problems.append(f"{key}: duplicate versions")
        if versions != [e.get("version") for e in sorted(lst, key=lambda e: version_key(e.get("version")), reverse=True)]:
            problems.append(f"{key}: not newest-first")
        for e in lst:
            for f in e.get("files", []):
                if not str(f.get("download_url", "")).startswith("https://"):
                    problems.append(f"{key} {e.get('version')}: {f.get('name')} has no https download_url")
                if not SHA.match(str(f.get("sha256", ""))):
                    problems.append(f"{key} {e.get('version')}: {f.get('name')} has no sha256")
    return problems


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    index = load()
    if cmd == "upsert-os" and len(sys.argv) == 3:
        with open(sys.argv[2]) as f:
            upsert_os(index, json.load(f))
    elif cmd == "sync-components" and len(sys.argv) == 2:
        sync_components(index)
    elif cmd == "check" and len(sys.argv) == 2:
        problems = check(index)
        for p in problems:
            print(f"{INDEX}: {p}", file=sys.stderr)
        sys.exit(1 if problems else 0)
    else:
        sys.exit(__doc__)
    dump(index)
    problems = check(index)
    if problems:
        for p in problems:
            print(f"{INDEX}: {p}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
