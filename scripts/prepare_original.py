#!/usr/bin/env python3
"""Prepare a byte-preserving baseline from the audited, pinned vendor inputs.

Only the original dylib and factory resource bundle are included. The source
archive is identified in manifest.json but is not needed for builds. No vendor
install script is included or executed; this script never signs or patches code.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import struct
import stat
import sys
import tempfile


PORT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_VENDOR = PORT_ROOT / "vendor" / "flydigi"
DEFAULT_RUNTIME = PORT_ROOT / "build" / "OriginalRuntime"
EXPECTED_DEB_SHA256 = "c1a189d607a72d60d9a0d410a3b50f6c78e41b8a2ff6396cb053b7536b663386"
EXPECTED_DYLIB_SHA256 = "d3a4482d37b12f833e153ded842bc86e4b814c5c68375fdb4159ce6bc42aca55"
EXPECTED_MANIFEST_SHA256 = "bfdcb43446a4035aa2ea1a918dbad1e91887acb2f4c5a293453af0b82aba1b0b"
EXPECTED_RESOURCE_INDEX_SHA256 = "f50423d098d1d10d8b965c0a18d240be0c8f3ac2a07381c314f9e40cf9371210"
RESOURCE_OUTPUT_ROOT = "FZKeymappingHelper.bundle"
EXPECTED_RESOURCE_COUNT = 476


class OriginalError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def archive_name(name: str) -> str:
    """Normalize only harmless tar './' prefixes; reject unsafe archive paths."""
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise OriginalError(f"Unsafe archive path: {name!r}")
    while name.startswith("./"):
        name = name[2:]
    name = name.rstrip("/")
    if name in ("", "."):
        return ""
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise OriginalError(f"Unsafe archive path: {name!r}")
    return str(PurePosixPath(name))


def _range(offset: int, size: int, limit: int, label: str) -> None:
    if offset < 0 or size < 0 or offset > limit or size > limit - offset:
        raise OriginalError(f"Out-of-bounds Mach-O {label}")


def _macho_name(raw: bytes) -> str:
    return raw.split(b"\x00", 1)[0].decode("ascii")


def inspect_macho(data: bytes) -> dict:
    """Record every section, including zero-fill layout and empty sections."""
    if len(data) < 32:
        raise OriginalError("Truncated Mach-O header")
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<8I", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C or subtype != 0 or filetype != 6:
        raise OriginalError("Expected the original thin little-endian arm64/ALL dylib, not arm64e or a fat image")
    _range(32, sizeofcmds, len(data), "load commands")
    if ncmds > sizeofcmds // 8:
        raise OriginalError("Invalid Mach-O load-command count")
    command_end = 32 + sizeofcmds
    position = 32
    sections = []
    segments = []
    for command_index in range(ncmds):
        _range(position, 8, command_end, "load-command header")
        command, command_size = struct.unpack_from("<II", data, position)
        if command_size < 8 or command_size % 8:
            raise OriginalError("Invalid Mach-O load-command size")
        _range(position, command_size, command_end, "load command")
        if command == 0x19:  # LC_SEGMENT_64
            if command_size < 72:
                raise OriginalError("Truncated LC_SEGMENT_64")
            values = struct.unpack_from("<II16sQQQQiiII", data, position)
            _, _, seg_raw, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = values
            segment = _macho_name(seg_raw)
            if 72 + nsects * 80 != command_size:
                raise OriginalError("Invalid section table size")
            _range(fileoff, filesize, len(data), f"segment {segment}")
            segments.append({"name": segment, "address": vmaddr, "virtual_size": vmsize,
                             "file_offset": fileoff, "file_size": filesize,
                             "maximum_protection": maxprot, "initial_protection": initprot,
                             "flags": segflags, "section_count": nsects})
            for index in range(nsects):
                fields = struct.unpack_from("<16s16sQQ8I", data, position + 72 + index * 80)
                sect_raw, sect_seg_raw, addr, size, offset, alignment, reloff, nreloc, sectflags, r1, r2, r3 = fields
                name, section_segment = _macho_name(sect_raw), _macho_name(sect_seg_raw)
                if section_segment != segment:
                    raise OriginalError("Mach-O section/segment name mismatch")
                zero_fill = (sectflags & 0xFF) in {1, 0xC, 0x12}
                if not zero_fill:
                    _range(offset, size, len(data), f"section {segment},{name}")
                    if size and (offset < fileoff or offset + size > fileoff + filesize):
                        raise OriginalError(f"Section {segment},{name} exceeds its file-backed segment")
                if addr < vmaddr or size > vmsize or addr - vmaddr > vmsize - size:
                    raise OriginalError(f"Section {segment},{name} exceeds its virtual segment")
                sections.append({"ordinal": len(sections) + 1, "segment": segment, "name": name,
                    "address": addr, "size": size, "file_offset": offset, "alignment_power": alignment,
                    "relocation_offset": reloff, "relocation_count": nreloc, "flags": sectflags,
                    "reserved1": r1, "reserved2": r2, "reserved3": r3, "zero_fill": zero_fill,
                    "sha256": None if zero_fill else sha256(data[offset:offset + size])})
        elif command == 0x1D:  # LC_CODE_SIGNATURE; reference only, not a signature-validity check.
            if command_size != 16:
                raise OriginalError("Invalid LC_CODE_SIGNATURE size")
            signature_offset, signature_size = struct.unpack_from("<II", data, position + 8)
            _range(signature_offset, signature_size, len(data), "code signature")
        position += command_size
    if position != command_end:
        raise OriginalError("Mach-O load commands do not fill their declared range")
    text_sections = [section for section in sections if (section["segment"], section["name"]) == ("__TEXT", "__text")]
    if len(text_sections) != 1 or not text_sections[0]["size"]:
        raise OriginalError("Missing or duplicate original __TEXT,__text")
    return {
        "header": {"magic": magic, "cpu_type": cpu, "cpu_subtype": subtype, "architecture": "arm64",
                   "file_type": filetype, "load_command_count": ncmds, "load_command_bytes": sizeofcmds,
                   "flags": flags, "reserved": reserved},
        "load_commands_sha256": sha256(data[32:command_end]),
        "text_section_sha256": text_sections[0]["sha256"],
        "segments": segments, "sections": sections,
        "section_coverage": {"all_sections_recorded": True, "section_count": len(sections),
                             "file_backed_section_count": sum(not section["zero_fill"] for section in sections),
                             "file_backed_section_bytes": sum(section["size"] for section in sections if not section["zero_fill"]),
                             "zero_fill_section_count": sum(section["zero_fill"] for section in sections)},
    }


def ordinary_bytes(path: Path, expected_size: int | None = None) -> bytes:
    """Do not follow a leaf symlink or read an unbounded/unexpected file."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise OriginalError(f"Cannot open ordinary input {path.name}: {error.strerror}") from error
    with os.fdopen(descriptor, "rb") as stream:
        information = os.fstat(stream.fileno())
        if not stat.S_ISREG(information.st_mode):
            raise OriginalError(f"Input is not a regular file: {path.name}")
        limit = expected_size if expected_size is not None else 1024 * 1024
        if information.st_size > limit or (expected_size is not None and information.st_size != expected_size):
            raise OriginalError(f"Unexpected input size: {path.name}")
        data = stream.read(limit + 1)
        if len(data) != information.st_size or len(data) > limit:
            raise OriginalError(f"Input changed while reading: {path.name}")
        return data


def inventory(root: Path) -> tuple[set[str], set[str]]:
    """Reject links and special objects before reading the exact input tree."""
    if root.is_symlink() or not root.is_dir():
        raise OriginalError("Input must be an existing real directory")
    files, directories = set(), set()
    for entry in root.rglob("*"):
        relative = entry.relative_to(root).as_posix()
        kind = entry.lstat().st_mode
        if stat.S_ISDIR(kind):
            directories.add(relative)
        elif stat.S_ISREG(kind):
            files.add(relative)
        else:
            raise OriginalError(f"Links and special files are not allowed: {relative}")
    return files, directories


def load_original(source: Path) -> tuple[dict, dict[str, bytes], dict[str, int], list[str]]:
    """Validate audited inputs against hashes fixed independently in this code."""
    observed_files, observed_directories = inventory(source)
    manifest_bytes = ordinary_bytes(source / "manifest.json")
    if sha256(manifest_bytes) != EXPECTED_MANIFEST_SHA256:
        raise OriginalError("Vendor manifest differs from the independently pinned original manifest")
    manifest = json.loads(manifest_bytes)
    if canonical_json(manifest) != manifest_bytes or manifest["source_deb"]["sha256"] != EXPECTED_DEB_SHA256:
        raise OriginalError("Vendor provenance does not match the original source archive")
    records = manifest["resources"]
    if len(records) != EXPECTED_RESOURCE_COUNT or sha256(canonical_json(records)) != EXPECTED_RESOURCE_INDEX_SHA256:
        raise OriginalError("Vendor resource index does not match the pinned factory resources")
    if manifest["resources_index_sha256"] != EXPECTED_RESOURCE_INDEX_SHA256:
        raise OriginalError("Vendor resource index declaration changed")
    directories = manifest["resource_directories"]
    if any(archive_name(name) != name or not (name == RESOURCE_OUTPUT_ROOT or name.startswith(RESOURCE_OUTPUT_ROOT + "/"))
           for name in directories):
        raise OriginalError("Unsafe vendor directory")
    expected_files = {"flydigi.dylib", "manifest.json"}
    for record in records:
        name = record["path"]
        if archive_name(name) != name or not name.startswith(RESOURCE_OUTPUT_ROOT + "/") or name in expected_files:
            raise OriginalError("Unsafe or duplicate vendor resource")
        expected_files.add(name)
    if observed_files != expected_files or observed_directories != set(directories):
        raise OriginalError("Vendor tree differs from the exact pinned files and directories")
    dylib_record = manifest["dylib"]
    dylib = ordinary_bytes(source / "flydigi.dylib", dylib_record["size"])
    if sha256(dylib) != EXPECTED_DYLIB_SHA256 or dylib_record["sha256"] != EXPECTED_DYLIB_SHA256:
        raise OriginalError("Vendor dylib does not match its independently pinned SHA256")
    if inspect_macho(dylib) != dylib_record["macho"]:
        raise OriginalError("Vendor Mach-O section inventory changed")
    files = {"flydigi.dylib": dylib}
    modes = {"flydigi.dylib": 0o644}
    for record in records:
        name = record["path"]
        data = ordinary_bytes(source / name, record["size"])
        if sha256(data) != record["sha256"]:
            raise OriginalError(f"Vendor factory resource changed: {name}")
        files[name] = data
        modes[name] = record["mode"] & 0o777
    return manifest, files, modes, directories


def check_runtime_tree(runtime: Path, manifest: dict, files: dict[str, bytes],
                       directories: list[str], check_dylib: bool = True) -> None:
    if runtime.is_symlink() or not runtime.is_dir():
        raise OriginalError("Runtime must be an existing real directory")
    expected_files = set(files) | {"manifest.json"}
    observed_files, observed_directories = set(), set()
    for entry in runtime.rglob("*"):
        relative = entry.relative_to(runtime).as_posix()
        if entry.is_symlink():
            raise OriginalError(f"Symlinks are not allowed in the baseline: {relative}")
        if entry.is_dir():
            observed_directories.add(relative)
        elif entry.is_file():
            observed_files.add(relative)
        else:
            raise OriginalError(f"Non-regular runtime entry: {relative}")
    if observed_files != expected_files or observed_directories != set(directories):
        missing = sorted(expected_files - observed_files)
        extra = sorted(observed_files - expected_files)
        raise OriginalError(f"Runtime tree differs from the original (missing={missing}, extra={extra}, directory_set_matches={observed_directories == set(directories)})")
    try:
        actual_manifest = json.loads((runtime / "manifest.json").read_text())
    except (UnicodeError, json.JSONDecodeError) as error:
        raise OriginalError(f"Invalid manifest: {error}") from error
    if actual_manifest != manifest:
        raise OriginalError("manifest.json differs from the independently pinned vendor manifest")
    for relative, original_bytes in files.items():
        if relative == "flydigi.dylib" and not check_dylib:
            continue
        actual = (runtime / relative).read_bytes()
        if actual != original_bytes:
            raise OriginalError(f"Original bytes changed: {relative} (expected {sha256(original_bytes)}, got {sha256(actual)})")


def prepare(source: Path, output: Path) -> dict:
    manifest, files, modes, directories = load_original(source)
    if output.exists() or output.is_symlink():
        check_runtime_tree(output, manifest, files, directories)
        return manifest
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".OriginalRuntime-", dir=output.parent) as staging_name:
        staging = Path(staging_name)
        for directory in directories:
            (staging / directory).mkdir(parents=True, exist_ok=True)
        for relative, payload in files.items():
            destination = staging / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as stream:
                stream.write(payload)
            destination.chmod(modes[relative])
        (staging / "manifest.json").write_bytes(canonical_json(manifest))
        check_runtime_tree(staging, manifest, files, directories)
        os.rename(staging, output)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, default=DEFAULT_VENDOR)
    parser.add_argument("--output", type=Path, default=DEFAULT_RUNTIME)
    args = parser.parse_args()
    try:
        manifest = prepare(args.vendor, args.output.absolute())
    except (OriginalError, OSError, UnicodeError) as error:
        print(f"Original preparation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"runtime": str(args.output.absolute()), "source_sha256": manifest["source_deb"]["sha256"],
                      "dylib_sha256": manifest["dylib"]["sha256"], "resource_files": len(manifest["resources"]),
                      "macho_sections": manifest["dylib"]["macho"]["section_coverage"]["section_count"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
