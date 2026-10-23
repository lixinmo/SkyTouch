#!/usr/bin/env python3
"""Audit only the Git index, or an explicit JSON source-file allowlist.

No device, generated build output, untracked file, network, or secret store is
read. Findings include paths and line numbers, never the matched secret value.
The frozen third-party factory dependency is accepted only by pinned hashes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
VENDOR = "vendor/flydigi/"
# The full reviewed digest is kept independently of the supplied manifest.
FACTORY_MANIFEST_SHA256 = "bfdcb43446a4035aa2ea1a918dbad1e91887acb2f4c5a293453af0b82aba1b0b"
FACTORY_DYLIB_SHA256 = "d3a4482d37b12f833e153ded842bc86e4b814c5c68375fdb4159ce6bc42aca55"
FACTORY_DEB_SHA256 = "c1a189d607a72d60d9a0d410a3b50f6c78e41b8a2ff6396cb053b7536b663386"
FACTORY_RESOURCES_SHA256 = "f50423d098d1d10d8b965c0a18d240be0c8f3ac2a07381c314f9e40cf9371210"
APP_ICON_HASHES = {
    "app/Icons/AppIcon20x20@2x.png": "b45ad5e8315786dfade0995c9853e9337a0a8b4540d90e96c20985e652f041da",
    "app/Icons/AppIcon20x20@3x.png": "4020c06c3873d1321eebb26dda942161272282ae256da462b4ae3144b6f16ea2",
    "app/Icons/AppIcon29x29@2x.png": "a6779e98bb286bff82cda5de4459cf2ee4d16e932482489e91bb729a1a0a1e76",
    "app/Icons/AppIcon29x29@3x.png": "0e86acf5c07422ffc2e91c14a03f46995088919d0a685e29238bc22151cec7db",
    "app/Icons/AppIcon40x40@2x.png": "b2fc5e4e11028e227444dedfb9945bd5e1946be7876c03f589c12a6b536c8394",
    "app/Icons/AppIcon40x40@3x.png": "1fb44b67319da23c0fb19fda54250a1a78f32ed3a78e97ecdd0b3432de48f783",
    "app/Icons/AppIcon60x60@2x.png": "1fb44b67319da23c0fb19fda54250a1a78f32ed3a78e97ecdd0b3432de48f783",
    "app/Icons/AppIcon60x60@3x.png": "8e5722a294687bbb05426d44f5a358ee3a30e10e3a5c3f496a3b5feeb5833c40"
}
ROOT_FILES = {".gitignore", "README.md", "LICENSE", "LICENSE.md", "NOTICE.md", "PRIVACY.md", "THIRD_PARTY_NOTICES.md"}
SOURCE_SUFFIXES = {
    "app": {".mm", ".c"}, "src": {".h", ".hpp", ".c", ".cpp", ".mm"},
    "shared": {".h", ".hpp", ".c", ".cpp", ".mm"},
    "scripts": {".py", ".sh"}, "licenses": {".txt"},
}
BLOCKED_COMPONENTS = {"tests", "fixtures", "build", "dist", "validation", "output", "outputs", "backup", "backups", "logs", "screenshots", "profiles", "globalrevisions", ".ssh", "__pycache__", ".ds_store"}
BLOCKED_SUFFIXES = {".pyc", ".pyo", ".o", ".a", ".deb", ".ipa", ".zip", ".tar", ".gz", ".xz", ".zst", ".log", ".jsonl", ".ndjson", ".skytouchbackup", ".pem", ".key", ".p12", ".pfx", ".mobileprovision", ".sqlite", ".db", ".binarycookies"}
UUID_PATTERN = re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")
# Only standard BLE protocol IDs are accepted in source code.
PROTOCOL_UUIDS = {"6E400001-B5A3-F393-E0A9-E50E24DCCA9E", "6E400002-B5A3-F393-E0A9-E50E24DCCA9E", "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"}
RULES = {
    "private key": re.compile(r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"),
    "SSH public credential": re.compile(r"\bssh-(?:rsa|ed25519)\s+[A-Za-z0-9+/]{40,}"),
    "GitHub credential": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "cloud access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "API credential": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b"),
    "Slack credential": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "personal email address": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}"),
    "modern device UDID": re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"),
    "legacy device UDID": re.compile(r"(?i)\budid[\s\"':=]+[0-9a-f]{40}\b"),
    "personal computer path": re.compile(r"(?<![A-Za-z0-9/:])/+(?:Users|home)/[A-Za-z0-9._-]+"),
    "Windows home path": re.compile(r"[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9._-]+"),
    "embedded URL credential": re.compile(r"https?://[^\s/'\"]+:[^\s/'\"]+@[^\s/'\"]+"),
    "literal credential assignment": re.compile(r"(?i)\b(?:password|passwd|api[_-]?key|access[_-]?token|client[_-]?secret|authorization)[\"']?\s*[:=]\s*@?[\"']([^\"'\r\n]{8,})[\"']"),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def safe_path(name):
    if not isinstance(name, str) or not name or "\\" in name or "\0" in name:
        return False
    path = PurePosixPath(name)
    return not path.is_absolute() and all(part not in {"", ".", ".."} for part in name.split("/"))


def load_index():
    listing = subprocess.run(["git", "ls-files", "--stage", "-z"], cwd=ROOT, check=True, capture_output=True).stdout
    entries = []
    for record in listing.split(b"\0"):
        if not record:
            continue
        metadata, raw_path = record.split(b"\t", 1)
        mode, oid, stage = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        if stage != "0" or mode not in {"100644", "100755"}:
            raise ValueError(f"Unmerged, linked, or non-file Git entry: {path}")
        if not safe_path(path):
            raise ValueError("Unsafe Git index path")
        entries.append((path, oid))
    if not entries:
        raise ValueError("Empty Git index; stage the reviewed source files first")
    result = subprocess.run(["git", "cat-file", "--batch"], cwd=ROOT, input="".join(oid + "\n" for _, oid in entries).encode(), check=True, capture_output=True).stdout
    position, files = 0, {}
    for path, oid in entries:
        end = result.index(b"\n", position)
        header = result[position:end].decode("ascii").split()
        if len(header) != 3 or header[:2] != [oid, "blob"]:
            raise ValueError(f"Cannot read indexed source: {path}")
        size = int(header[2]); position = end + 1
        files[path] = result[position:position + size]; position += size
        if result[position:position + 1] != b"\n":
            raise ValueError("Invalid Git blob output")
        position += 1
    if position != len(result):
        raise ValueError("Unexpected Git blob output")
    return files


def load_manifest(path):
    names = json.loads(path.read_text())
    if not isinstance(names, list) or not names or len(set(names)) != len(names):
        raise ValueError("Source allowlist must be a nonempty JSON array of unique relative paths")
    files = {}
    for name in names:
        if not safe_path(name):
            raise ValueError("Unsafe source allowlist path")
        current = ROOT
        for part in PurePosixPath(name).parts:
            current /= part
            if current.is_symlink():
                raise ValueError(f"Symlink in source allowlist: {name}")
        if not stat.S_ISREG(current.stat().st_mode):
            raise ValueError(f"Not an ordinary source file: {name}")
        files[name] = current.read_bytes()
    return files


def approved_vendor(files):
    name = VENDOR + "manifest.json"
    data = files.get(name, b"")
    if digest(data) != FACTORY_MANIFEST_SHA256:
        raise ValueError("Missing or changed independently pinned factory manifest")
    manifest = json.loads(data)
    if manifest["source_deb"]["sha256"] != FACTORY_DEB_SHA256 or manifest["dylib"]["sha256"] != FACTORY_DYLIB_SHA256:
        raise ValueError("Factory dependency origin mismatch")
    resources = manifest["resources"]
    if len(resources) != 476 or digest(canonical(resources)) != FACTORY_RESOURCES_SHA256:
        raise ValueError("Factory resource index mismatch")
    expected = {name: digest(data), VENDOR + "flydigi.dylib": FACTORY_DYLIB_SHA256}
    for item in resources:
        if not safe_path(item["path"]) or not item["path"].startswith("FZKeymappingHelper.bundle/"):
            raise ValueError("Unsafe factory resource path")
        expected[VENDOR + item["path"]] = item["sha256"]
    for name, expected_hash in expected.items():
        if name not in files or digest(files[name]) != expected_hash:
            raise ValueError(f"Missing or altered factory input: {name}")
    return set(expected)


def allowed_source_path(path):
    if path in ROOT_FILES:
        return True
    parts = PurePosixPath(path).parts
    suffix = PurePosixPath(path).suffix.lower()
    if any(part.lower() in BLOCKED_COMPONENTS for part in parts) or suffix in BLOCKED_SUFFIXES:
        return False
    if path.startswith(".github/workflows/"):
        return len(parts) == 3 and suffix in {".yml", ".yaml"}
    if path.startswith("app/Icons/"):
        return re.fullmatch(r"app/Icons/AppIcon(20x20|29x29|40x40|60x60)@[23]x\.png", path) is not None
    if path in {"app/Info.plist", "packaging/preinst", "packaging/postinst", "packaging/prerm", "packaging/postrm",
                "packaging/SkyTouchButtons.plist", "springboard/OPPhoneButtonCapture.mm", "springboard/OPPhoneButtonTransport.hpp",
                "packaging/MappingService-Info.plist", "packaging/BluetoothService-Info.plist",
                "packaging/host-entitlements.plist", "packaging/bluetooth-entitlements.plist", "packaging/storage-entitlements.plist"}:
        return True
    if parts[0] in SOURCE_SUFFIXES:
        return suffix in SOURCE_SUFFIXES[parts[0]]
    if path.startswith("vendor/fishhook/"):
        return parts[-1] in {"fishhook.c", "fishhook.h", "LICENSE", "ORIGIN.json"} and len(parts) == 3
    if path.startswith(VENDOR):
        return parts[-1] in {"README.md", "NOTICE.md", "ORIGIN.json"} and len(parts) == 3
    return False


def source_exception(path, category, match):
    # Retina icon filenames contain @ and can resemble an email address.
    return category == "personal email address" and match.group() in {
        PurePosixPath(name).name for name in APP_ICON_HASHES
    }


def audit(files):
    findings = []
    vendor_files = approved_vendor(files)
    for path, data in files.items():
        if path in vendor_files:
            continue
        if not allowed_source_path(path):
            findings.append(f"{path}: forbidden or unreviewed source path")
            continue
        if path.startswith("app/Icons/"):
            # Byte-pinned artwork was independently inspected, including its
            # metadata. Renamed screenshots must not masquerade as App icons.
            if digest(data) != APP_ICON_HASHES.get(path):
                findings.append(f"{path}: unreviewed application artwork")
                continue
            import struct
            if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
                findings.append(f"{path}: invalid application icon")
                continue
            points, scale = map(int, re.search(r'AppIcon(\d+)x\d+@(\d)x', path).groups())
            width, height, depth, color = struct.unpack_from(">IIBB", data, 16)
            if (width, height, depth, color) != (points * scale, points * scale, 8, 2):
                findings.append(f"{path}: unexpected application icon format")
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            findings.append(f"{path}: unreviewed binary data")
            continue
        if "\0" in text:
            findings.append(f"{path}: unexpected binary data")
            continue
        for category, expression in RULES.items():
            for match in expression.finditer(text):
                if not source_exception(path, category, match):
                    findings.append(f"{path}:{text.count(chr(10), 0, match.start()) + 1}: {category}")
        for match in UUID_PATTERN.finditer(text):
            value = match.group().upper()
            if value not in PROTOCOL_UUIDS:
                findings.append(f"{path}:{text.count(chr(10), 0, match.start()) + 1}: unreviewed persistent UUID")
    return findings, len(vendor_files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="Audit this explicit JSON file list instead of the Git index")
    args = parser.parse_args()
    try:
        files = load_manifest(args.manifest) if args.manifest else load_index()
        findings, vendor_count = audit(files)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(f"Source privacy audit could not complete: {error}", file=sys.stderr)
        return 1
    if findings:
        print("Source privacy audit rejected the candidate:", file=sys.stderr)
        for finding in findings:
            print("- " + finding, file=sys.stderr)
        return 1
    print(json.dumps({"privacy_audit": "passed", "source": "allowlist" if args.manifest else "git-index", "candidate_files": len(files), "pinned_factory_files": vendor_count, "device_or_generated_data_read": False}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
