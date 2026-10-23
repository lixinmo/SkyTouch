#!/usr/bin/env python3
"""Prove prepared resources and original sections match the pinned vendor inputs.

By default the dylib must match byte for byte before signing. --runtime-dylib
additionally checks a signed/copied dylib against EVERY original section. Only
Mach-O header/load-command and non-section data (such as the signature/linkedit
tables) may differ. This does not verify signature validity, successful loading,
UI operation, or the behavior of separately installed hooks.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import sys


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "prepare_original.py"
SPEC = importlib.util.spec_from_file_location("skytouch_prepare_original", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot import the original-source verifier")
original = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(original)


def verify_sections(runtime: bytes, baseline: dict) -> dict:
    inspected = original.inspect_macho(runtime)
    expected = baseline["dylib"]["macho"]
    for key in ("magic", "cpu_type", "cpu_subtype", "file_type", "flags", "reserved"):
        if inspected["header"][key] != expected["header"][key]:
            raise original.OriginalError(f"Runtime Mach-O header changed beyond signing/load-command sizes: {key}")
    if len(inspected["sections"]) != len(expected["sections"]):
        raise original.OriginalError("Runtime added or removed Mach-O sections")
    # Signing/tooling may move file offsets, but not section identities, memory
    # layout, permissions/type flags, relocations or any actual section byte.
    stable_keys = ("ordinal", "segment", "name", "address", "size", "alignment_power", "flags",
                   "relocation_count", "reserved1", "reserved2", "reserved3", "zero_fill", "sha256")
    for reference, actual in zip(expected["sections"], inspected["sections"]):
        label = f'{reference["segment"]},{reference["name"]}'
        for key in stable_keys:
            if actual[key] != reference[key]:
                raise original.OriginalError(f"Runtime section changed: {label} ({key})")
    expected_segments = expected["segments"]
    if len(inspected["segments"]) != len(expected_segments):
        raise original.OriginalError("Runtime added or removed segments")
    for reference, actual in zip(expected_segments, inspected["segments"]):
        keys = ("name", "address", "maximum_protection", "initial_protection", "flags", "section_count")
        if reference["name"] != "__LINKEDIT":
            keys += ("virtual_size",)
        for key in keys:
            if actual[key] != reference[key]:
                raise original.OriginalError(f'Runtime segment changed: {reference["name"]} ({key})')
    return inspected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor", type=Path, default=original.DEFAULT_VENDOR)
    parser.add_argument("--runtime-dir", type=Path, default=original.DEFAULT_RUNTIME)
    parser.add_argument("--runtime-dylib", type=Path,
                        help="Signed runtime copy; all original sections must remain unchanged")
    args = parser.parse_args()
    try:
        # Never trust the prepared manifest as its own authority: validate the
        # source vendor inputs against independently pinned hashes on each run.
        manifest, files, _modes, directories = original.load_original(args.vendor)
        prepared_dylib = args.runtime_dir / "flydigi.dylib"
        same_signed_path = args.runtime_dylib is not None and args.runtime_dylib.resolve() == prepared_dylib.resolve()
        original.check_runtime_tree(args.runtime_dir, manifest, files, directories, check_dylib=not same_signed_path)
        mode = "exact-original-bytes"
        if args.runtime_dylib is not None:
            if args.runtime_dylib.is_symlink() or not args.runtime_dylib.is_file():
                raise original.OriginalError("Signed runtime dylib must be an ordinary file")
            verify_sections(args.runtime_dylib.read_bytes(), manifest)
            mode = "all-original-sections-unchanged"
    except (original.OriginalError, OSError, UnicodeError, AssertionError) as error:
        print(f"Original verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"verified": True, "mode": mode, "resources": len(manifest["resources"]),
                      "sections": len(manifest["dylib"]["macho"]["sections"]),
                      "text_sha256": manifest["dylib"]["macho"]["text_section_sha256"],
                      "device_loading_or_behavior_verified": False}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
