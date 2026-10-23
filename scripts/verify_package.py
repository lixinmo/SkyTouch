#!/usr/bin/env python3
"""Inspect an SkyTouch candidate deb; never install or run package scripts.

These checks establish archive scope, signatures and preserved vendor sections,
not device acceptance, entitlement grants, login success or touch delivery.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import io
import json
import lzma
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = "Applications/SkyTouch.app/"
TWEAK_DIRECTORY = "Library/MobileSubstrate/DynamicLibraries/"
TWEAK_BINARY = TWEAK_DIRECTORY + "SkyTouchButtons.dylib"
TWEAK_FILTER = TWEAK_DIRECTORY + "SkyTouchButtons.plist"
OWN_BINARIES = ("SkyTouch", "SkyTouchControl", "SkyTouchStorage", "SystemMapping.bundle/SkyTouchMapping", "SystemBluetooth.bundle/SkyTouchBLE")
SCRIPTS = ("preinst", "postinst", "prerm", "postrm")
MAX_ARCHIVE = 128 * 1024 * 1024
APP_ICON_POINTS = (20, 29, 40, 60)


def app_icons():
    icons = {}
    for points in APP_ICON_POINTS:
        for scale in (2, 3):
            name = f"AppIcon{points}x{points}@{scale}x.png"
            data = (ROOT / "app/Icons" / name).read_bytes()
            require(len(data) >= 33 and data[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", f"Invalid App icon PNG: {name}")
            width, height, depth, color = struct.unpack_from(">IIBB", data, 16)
            require((width, height, depth, color) == (points * scale, points * scale, 8, 2), f"App icon must be opaque RGB at its declared size: {name}")
            icons[name] = data
    return icons


def require(condition, message):
    if not condition:
        raise ValueError(message)


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def version_for(info):
    short, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    require(isinstance(short, str) and re.fullmatch(r"\d+\.\d+\.\d+(?:-dev)?", short), "Unsupported bundle version format")
    require(isinstance(build, str) and re.fullmatch(r"[1-9]\d{0,8}", build), "Invalid CFBundleVersion")
    return short.removesuffix("-dev") + "~dev" + build if short.endswith("-dev") else short


def control_for(info):
    return ("Package: com.lixinmo.skytouch\nName: 凌触 SkyTouch\n"
            f"Version: {version_for(info)}\nArchitecture: iphoneos-arm64e\n"
            "Description: 手柄与手机按键系统级触屏映射，支持共用方案、手机体感和飞智云方案。\n"
            "Maintainer: SkyTouch Local Build\nAuthor: SkyTouch Local Build\nSection: Utilities\n").encode()


def verify_ios_deployment(data):
    """Check load commands, not just the installer/plist labels."""
    require(len(data) >= 32 and struct.unpack_from("<I", data)[0] == 0xFEEDFACF, "Invalid 64-bit Mach-O")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset, limit, versions = 32, 32 + sizeofcmds, []
    require(limit <= len(data) and ncmds <= sizeofcmds // 8, "Invalid Mach-O command table")
    for _ in range(ncmds):
        require(offset + 8 <= limit, "Truncated Mach-O command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and size % 8 == 0 and offset + size <= limit, "Invalid Mach-O command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated build version")
            platform, minimum = struct.unpack_from("<II", data, offset + 8)
            require(platform == 2, "Service must target iOS devices")
            versions.append(minimum)
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            require(size >= 16, "Truncated minimum iOS version")
            versions.append(struct.unpack_from("<I", data, offset + 8)[0])
        offset += size
    require(offset == limit and versions, "Missing or invalid deployment version")
    require(all(0 < value <= 0x000F0000 for value in versions), "Own binary still imposes a deployment target above iOS 15.0")


def verify_button_binary(data):
    verify_ios_deployment(data)
    magic, cpu, subtype, kind = struct.unpack_from("<4I", data)
    require((magic, cpu, subtype & 0x00FFFFFF, kind) == (0xFEEDFACF, 0x0100000C, 2, 6),
            "Button capture must be a thin arm64e iOS dylib")
    allowed = {"/usr/lib/libobjc.A.dylib", "/usr/lib/libSystem.B.dylib", "/usr/lib/libc++.1.dylib",
               "/System/Library/Frameworks/Foundation.framework/Foundation",
               "/System/Library/Frameworks/UIKit.framework/UIKit",
               "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"}
    offset = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if command in (0xC, 0x80000018, 0x8000001F, 0xD):
            require(size >= 24, "Truncated button dylib dependency")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            require(24 <= name_offset < size, "Invalid button dylib dependency name")
            name = data[offset + name_offset:offset + size].split(b"\0", 1)[0].decode("utf-8")
            require(name == "/" + TWEAK_BINARY if command == 0xD else name in allowed,
                    "Unexpected button dylib identity/dependency: " + name)
        offset += size


def verify_scripts(control):
    require(set(control) == {"control", *SCRIPTS}, "Unexpected maintainer script or control payload")
    for name in SCRIPTS:
        script, mode = control[name]
        require(script == (ROOT / "packaging" / name).read_bytes() and mode == 0o755, f"Unreviewed {name}")
        subprocess.run(["/bin/sh", "-n"], input=script, check=True)  # Syntax only.
        active = "\n".join(line for line in script.decode().splitlines() if not line.lstrip().startswith("#"))
        scoped = active.replace("/Applications/SkyTouch.app/Original/flydigi.dylib", "OWN_VENDOR_LIBRARY")
        scoped = scoped.replace("/" + TWEAK_BINARY, "OWN_BUTTON_LIBRARY")
        forbidden_operations = ("flydigi", "MobileSubstrate", "DynamicLibraries", "dpkg", "apt", "launchctl", "mv ", "cp ", "respring", "uicache -a")
        if name != "postrm":
            forbidden_operations += ("rm ",)
        # postrm has reviewed, fixed-scope removal of this package's own data.
        # Exact script equality above rejects any unreviewed wider operation.
        for forbidden in forbidden_operations:
            require(forbidden not in scoped, f"External-package or broad operation in {name}: {forbidden}")
        kill_lines = [line.strip() for line in active.splitlines() if "/usr/bin/killall -" in line]
        if name in ("preinst", "prerm"):
            require(kill_lines == [
                "if task_probe_output=$(/usr/bin/killall -0 SkyTouchPackageProbeNotRunning 2>&1); then",
                'if task_output=$(/usr/bin/killall -0 "$task_program" 2>&1); then'], "Only exact own-name signal-0 checks are permitted")
            require("for task_program in SkyTouch SkyTouchMapping SkyTouchBLE; do" in active, "Process checks must stay within this package")
            require("No matching processes were found" in active and '"$task_result" -ne 1' in active, "Missing fail-closed process result check")
            helper_lines = [line.strip() for line in active.splitlines()
                            if "/Applications/SkyTouch.app/SkyTouchControl" in line and " -x " not in line]
            require(helper_lines == [
                "if ! /Applications/SkyTouch.app/SkyTouchControl --package-maintenance; then",
                "/Applications/SkyTouch.app/SkyTouchControl || true"],
                "Package maintenance must release button capture with the own helper, retaining only the 1.0 fallback")
            require("notifyutil -p com.lixinmo.skytouch.buttons.maintenance || true" in active,
                    "Missing exact button-capture maintenance notification")
        else:
            require(not kill_lines, "Unexpected process operation")
            require("--package-maintenance" not in active, "Package-only control flag used outside preinst/prerm")
        for line in active.splitlines():
            if "notifyutil -p" in line:
                require(re.fullmatch(r"\s*notifyutil -p com\.lixinmo\.skytouch(?:\.[a-z-]+)* \|\| true", line), "Notification outside this package")


def verify_control(control, info):
    verify_scripts(control)
    require(control["control"] == (control_for(info), 0o644), "Unreviewed control fields/version/dependencies")


def read_ar(data):
    require(len(data) <= MAX_ARCHIVE and data.startswith(b"!<arch>\n"), "Invalid/oversized deb")
    members = {}; offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        require(len(header) == 60 and header[58:] == b"`\n", "Invalid ar header")
        name = header[:16].decode("ascii").strip().removesuffix("/")
        require(name in ("debian-binary", "control.tar.xz", "data.tar.xz") and name not in members, "Unexpected/duplicate ar member")
        size = int(header[48:58].decode("ascii").strip()); offset += 60
        require(size >= 0 and offset + size <= len(data), "Truncated ar member")
        members[name] = data[offset:offset + size]; offset += size
        if size & 1:
            require(data[offset:offset + 1] == b"\n", "Invalid ar padding"); offset += 1
    require(list(members) == ["debian-binary", "control.tar.xz", "data.tar.xz"] and members["debian-binary"] == b"2.0\n", "Unexpected deb layout")
    return members


def read_tar(data, app_only=False):
    decoder = lzma.LZMADecompressor()
    raw = decoder.decompress(data, max_length=MAX_ARCHIVE + 1)
    require(len(raw) <= MAX_ARCHIVE and decoder.eof and not decoder.unused_data, "Oversized or incomplete tar.xz")
    files = {}; names = set()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for entry in archive:
            name = entry.name.removeprefix("./").rstrip("/")
            require(name and not name.startswith("/") and all(part not in ("", ".", "..") for part in name.split("/")), "Unsafe package path")
            require(name not in names and not entry.pax_headers, "Duplicate/PAX archive entry"); names.add(name)
            require(entry.uid == entry.gid == 0 and not entry.mode & 0o7022, "Privileged/writable package mode")
            require(entry.isdir() or entry.isfile(), "Links or special entries in package")
            if entry.isdir():
                require(app_only and (name == "Applications" or name == APP.rstrip("/") or name.startswith(APP) or
                        name in {"Library", "Library/MobileSubstrate", TWEAK_DIRECTORY.rstrip("/")}),
                        "Directory outside this package's exact application/tweak scope")
            if entry.isfile():
                files[name] = (archive.extractfile(entry).read(), entry.mode)
    return files


def source_resources():
    original = module(ROOT / "scripts/prepare_original.py", "op_package_original")
    manifest, files, _, _ = original.load_original(original.DEFAULT_VENDOR)
    return manifest, files


def verify_payload(files, manifest, originals):
    licenses = {"Licenses/" + path.name: path.read_bytes() for path in (ROOT / "licenses").glob("*.txt")}
    icons = app_icons()
    resources = {name: data for name, data in originals.items() if name != "flydigi.dylib"}
    mapping_resources = {"SystemMapping.bundle/" + name: data for name, data in resources.items()}
    resources = resources | mapping_resources
    expected = {APP + name for name in resources | licenses | icons} | {
        APP + "SkyTouch", APP + "SkyTouchControl", APP + "SkyTouchStorage", APP + "Info.plist", APP + "Original/flydigi.dylib", APP + "_CodeSignature/CodeResources",
        APP + "SystemMapping.bundle/Info.plist", APP + "SystemMapping.bundle/SkyTouchMapping", APP + "SystemMapping.bundle/_CodeSignature/CodeResources",
        APP + "SystemBluetooth.bundle/Info.plist", APP + "SystemBluetooth.bundle/SkyTouchBLE", APP + "SystemBluetooth.bundle/_CodeSignature/CodeResources",
        TWEAK_BINARY, TWEAK_FILTER}
    require(set(files) == expected, "Payload differs from exact App plus two button-tweak files (no probes, profiles, credentials or validation helpers)")
    for name, data in (resources | licenses | icons).items():
        require(files[APP + name][0] == data, f"Resource/license changed: {name}")
    for name, (_, mode) in files.items():
        require(mode == (0o755 if name == TWEAK_BINARY or name.removeprefix(APP) in (*OWN_BINARIES, "Original/flydigi.dylib") else 0o644), f"Unexpected file mode: {name}")
    require(files[TWEAK_FILTER][0] == (ROOT / "packaging/SkyTouchButtons.plist").read_bytes(), "Button filter differs from reviewed source")
    filter_data = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", "-"],
                                 input=files[TWEAK_FILTER][0], check=True, capture_output=True).stdout
    require(plistlib.loads(filter_data) == {"Filter": {"Bundles": ["com.apple.springboard"]}},
            "Button capture must inject only into SpringBoard")
    verify_button_binary(files[TWEAK_BINARY][0])
    source_info = (ROOT / "app/Info.plist").read_bytes()
    require(files[APP + "Info.plist"][0] == source_info, "Candidate Info.plist differs from current source; rebuild before packaging")
    info = plistlib.loads(source_info)
    require("MinimumOSVersion" not in info, "App metadata must not reintroduce a firmware installation gate")
    require(info["CFBundleIdentifier"] == "com.lixinmo.skytouch.app" and info["CFBundleExecutable"] == "SkyTouch", "Wrong application identity")
    require(info.get("CFBundleIcons") == {"CFBundlePrimaryIcon": {
        "CFBundleIconFiles": [f"AppIcon{points}x{points}" for points in APP_ICON_POINTS]}}, "Missing or incorrect App icon registration")
    version_for(info)
    require(files[APP + "SystemBluetooth.bundle/Info.plist"][0] == (ROOT / "packaging/BluetoothService-Info.plist").read_bytes(), "Unreviewed system service identity")
    service_info = plistlib.loads(files[APP + "SystemBluetooth.bundle/Info.plist"][0])
    require("MinimumOSVersion" not in service_info, "Service metadata must not reintroduce a firmware installation gate")
    require(service_info.get("CFBundleIdentifier") == "SkyTouchBLE" and
            service_info.get("CFBundleExecutable") == "SkyTouchBLE" and
            service_info.get("CFBundlePackageType") == "BNDL",
            "Bluetooth must identify as its own standalone daemon, not an unregistered dotted App identity")
    require(files[APP + "SystemMapping.bundle/Info.plist"][0] == (ROOT / "packaging/MappingService-Info.plist").read_bytes(), "Unreviewed mapping service identity")
    mapping_info = plistlib.loads(files[APP + "SystemMapping.bundle/Info.plist"][0])
    require("MinimumOSVersion" not in mapping_info, "Mapping service metadata must not impose a firmware gate")
    require(mapping_info.get("CFBundleIdentifier") == "SkyTouchMapping" and
            mapping_info.get("CFBundleExecutable") == "SkyTouchMapping" and
            mapping_info.get("CFBundlePackageType") == "BNDL", "Mapping must have its own service identity")
    binary = files[APP + "SkyTouch"][0]
    require(len(binary) >= 32 and struct.unpack_from("<4I", binary) == (0xFEEDFACF, 0x0100000C, 0, 2), "Host must be a thin arm64 iOS executable")
    for own_binary in OWN_BINARIES:
        verify_ios_deployment(files[APP + own_binary][0])
    verifier = module(ROOT / "scripts/verify_original.py", "op_package_vendor_sections")
    verifier.verify_sections(files[APP + "Original/flydigi.dylib"][0], manifest)
    with tempfile.TemporaryDirectory(prefix="skytouch-package-verify-") as directory:
        root = Path(directory)
        for name, (data, mode) in files.items():
            destination = root / name; destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data); destination.chmod(mode)
        app = root / "Applications/SkyTouch.app"
        buttons = root / TWEAK_BINARY
        subprocess.run(["codesign", "--verify", "--strict", str(buttons)], check=True, capture_output=True)
        buttons_signature = subprocess.run(["codesign", "-d", "-v", str(buttons)], check=True, capture_output=True)
        require(b"Identifier=com.lixinmo.skytouch.buttons\n" in buttons_signature.stderr, "Wrong signed button-capture identity")
        buttons_entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(buttons)], check=True, capture_output=True)
        require(not buttons_entitlements.stdout.strip() or plistlib.loads(buttons_entitlements.stdout) == {},
                "Button capture must not introduce its own entitlements")
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--strict", str(app / "Original/flydigi.dylib")], check=True, capture_output=True)
        subprocess.run(["codesign", "--verify", "--strict", str(app / "SkyTouchControl")], check=True, capture_output=True)
        storage = app / "SkyTouchStorage"
        subprocess.run(["codesign", "--verify", "--strict", str(storage)], check=True, capture_output=True)
        storage_signature = subprocess.run(["codesign", "-d", "-v", str(storage)], check=True, capture_output=True)
        require(b"Identifier=com.lixinmo.skytouch.storage\n" in storage_signature.stderr, "Wrong storage maintenance identity")
        storage_entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(storage)], check=True, capture_output=True)
        require(plistlib.loads(storage_entitlements.stdout) == plistlib.loads((ROOT / "packaging/storage-entitlements.plist").read_bytes()), "Storage maintenance permissions differ from reviewed plist")
        service = app / "SystemBluetooth.bundle"
        subprocess.run(["codesign", "--verify", "--strict", str(service)], check=True, capture_output=True)
        service_signature = subprocess.run(["codesign", "-d", "-v", str(service)], check=True, capture_output=True)
        require(b"Identifier=SkyTouchBLE\n" in service_signature.stderr, "Wrong signed Bluetooth daemon identity")
        service_entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(service)], check=True, capture_output=True)
        require(plistlib.loads(service_entitlements.stdout) == plistlib.loads((ROOT / "packaging/bluetooth-entitlements.plist").read_bytes()), "System Bluetooth permissions differ from reviewed plist")
        mapping_service = app / "SystemMapping.bundle"
        subprocess.run(["codesign", "--verify", "--strict", str(mapping_service)], check=True, capture_output=True)
        mapping_signature = subprocess.run(["codesign", "-d", "-v", str(mapping_service)], check=True, capture_output=True)
        require(b"Identifier=SkyTouchMapping\n" in mapping_signature.stderr, "Wrong signed mapping service identity")
        mapping_entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(mapping_service)], check=True, capture_output=True)
        require(plistlib.loads(mapping_entitlements.stdout) == plistlib.loads((ROOT / "packaging/host-entitlements.plist").read_bytes()), "Mapping permissions differ from reviewed host plist")
        actual = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
        require(plistlib.loads(actual.stdout) == plistlib.loads((ROOT / "packaging/host-entitlements.plist").read_bytes()), "Entitlements differ from reviewed host plist")
    return info


def candidate_files(path, tweaks=None):
    require(path.is_dir() and not path.is_symlink(), "Candidate must be a real app directory")
    files = {}
    for entry in path.rglob("*"):
        require(not entry.is_symlink(), "Candidate contains a symlink")
        if entry.is_dir():
            continue
        require(entry.is_file(), "Candidate contains a special file")
        relative = entry.relative_to(path).as_posix()
        mode = 0o755 if relative in (*OWN_BINARIES, "Original/flydigi.dylib") else 0o644
        files[APP + relative] = (entry.read_bytes(), mode)
    tweaks = tweaks if tweaks is not None else path.parent / TWEAK_DIRECTORY
    require(tweaks.is_dir() and not tweaks.is_symlink(), "Button-tweak candidate directory is missing or linked")
    require({entry.name for entry in tweaks.iterdir()} == {"SkyTouchButtons.dylib", "SkyTouchButtons.plist"},
            "Button-tweak candidate contains unexpected files")
    for name in ("SkyTouchButtons.dylib", "SkyTouchButtons.plist"):
        entry = tweaks / name
        require(entry.is_file() and not entry.is_symlink(), "Button-tweak candidate must contain only ordinary files")
        files[TWEAK_DIRECTORY + name] = (entry.read_bytes(), 0o755 if name.endswith(".dylib") else 0o644)
    return files


def verify(path):
    members = read_ar(path.read_bytes())
    control, files = read_tar(members["control.tar.xz"]), read_tar(members["data.tar.xz"], app_only=True)
    verify_scripts(control)
    manifest, originals = source_resources()
    info = verify_payload(files, manifest, originals)
    verify_control(control, info)
    return {"package": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "version": version_for(info),
            "app_only": False, "button_capture_filter": "com.apple.springboard", "external_packages_managed": False,
            "candidate_acceptance": "pending", "device_install_verified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.package.resolve()), ensure_ascii=False, sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError, lzma.LZMAError) as error:
        print(f"Candidate package rejected: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
