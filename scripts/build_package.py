#!/usr/bin/env python3
"""Package an already-built, signed SkyTouch candidate. Never deploy/install.

Run build_candidate.sh separately first, after all runtime edits have finished.
Version comes from the current app Info.plist, including CFBundleVersion. The
Packaging verification is separate from runtime acceptance on a device.
"""
from __future__ import annotations
import argparse
import importlib.util
import io
import json
import lzma
from pathlib import Path, PurePosixPath
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("op_candidate_package_verifier", ROOT / "scripts/verify_package.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def tar_xz(files, include_directories):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:", format=tarfile.USTAR_FORMAT) as archive:
        if include_directories:
            directories = set()
            for name in files:
                directories.update(str(parent) for parent in PurePosixPath(name).parents if str(parent) != ".")
            for name in sorted(directories, key=lambda item: (item.count("/"), item)):
                member = tarfile.TarInfo(name); member.type = tarfile.DIRTYPE; member.mode = 0o755
                member.uid = member.gid = member.mtime = 0; member.uname = "root"; member.gname = "wheel"
                archive.addfile(member)
        for name, (data, mode) in sorted(files.items()):
            member = tarfile.TarInfo(name); member.size = len(data); member.mode = mode
            member.uid = member.gid = member.mtime = 0; member.uname = "root"; member.gname = "wheel"
            archive.addfile(member, io.BytesIO(data))
    return lzma.compress(stream.getvalue(), format=lzma.FORMAT_XZ, preset=6)


def write_deb(path, control, payload):
    with path.open("wb") as output:
        output.write(b"!<arch>\n")
        for name, data in (("debian-binary", b"2.0\n"), ("control.tar.xz", tar_xz(control, False)), ("data.tar.xz", tar_xz(payload, True))):
            output.write(f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode("ascii"))
            output.write(data)
            if len(data) & 1:
                output.write(b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, default=ROOT / "build/Candidate/SkyTouch.app")
    parser.add_argument("--tweaks", type=Path, help="Reviewed button-tweak directory; defaults beside the candidate App")
    args = parser.parse_args()
    files = verifier.candidate_files(args.candidate.absolute(), args.tweaks.absolute() if args.tweaks else None)
    manifest, originals = verifier.source_resources()
    info = verifier.verify_payload(files, manifest, originals)
    control = {"control": (verifier.control_for(info), 0o644)}
    control.update({name: ((ROOT / "packaging" / name).read_bytes(), 0o755) for name in verifier.SCRIPTS})
    verifier.verify_scripts(control)
    destination = ROOT / "dist"; destination.mkdir(exist_ok=True)
    name = f"com.lixinmo.skytouch_{verifier.version_for(info)}_iphoneos-arm64e.deb"
    with tempfile.TemporaryDirectory(prefix=".candidate-package-", dir=destination) as directory:
        staged = Path(directory) / name
        write_deb(staged, control, files)
        result = verifier.verify(staged)
        package = destination / name
        staged.replace(package)
    result["package"] = str(package)
    result["status"] = "Package integrity verified; not installed by this packaging run"
    (destination / (name + ".verification.json")).write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
