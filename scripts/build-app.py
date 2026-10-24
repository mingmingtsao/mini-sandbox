#!/usr/bin/env python3
"""Build a locally runnable macOS app; never recursively delete output paths."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MARKER = ".mini-sandbox-owner"


def run(*args: str) -> None:
    subprocess.run(args, cwd=ROOT, check=True)


def safe_directory(path: Path):
    """Reject links, foreign owners and group/world-writable output directories."""
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise RuntimeError("Unsafe output directory: " + str(path))
    return info.st_dev, info.st_ino


def ownership(app: Path):
    return {"format": 1, "project_root": str(ROOT.resolve()), "output": str(app)}


def check_existing(app: Path):
    if not os.path.lexists(app):
        return None
    identity = safe_directory(app)
    marker = app / "Contents/Resources" / MARKER
    try:
        safe_directory(app / "Contents")
        safe_directory(app / "Contents/Resources")
        info = marker.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_size > 4096:
            raise RuntimeError("Unsafe ownership marker: " + str(marker))
        if json.loads(marker.read_text()) != ownership(app):
            raise RuntimeError("Output belongs to another build: " + str(app))
    except (OSError, ValueError) as error:
        raise RuntimeError("Unmarked output preserved; move it aside before building: " + str(app)) from error
    return identity


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--sign-identity", default="-", help="codesign identity; default is local ad-hoc signing")
    args = parser.parse_args()
    root_identity = safe_directory(ROOT)
    dist = ROOT / "dist"
    if not os.path.lexists(dist):
        dist.mkdir(mode=0o755)
    dist_identity = safe_directory(dist)
    app = dist / "MiniSandbox.app"
    previous_identity = check_existing(app)

    run("swift", "build", "-c", args.configuration, "--product", "MiniSandbox")
    bin_path = Path(subprocess.check_output(["swift", "build", "-c", args.configuration, "--show-bin-path"], cwd=ROOT, text=True).strip())
    binary = bin_path / "MiniSandbox"
    if not binary.is_file() or binary.is_symlink():
        raise RuntimeError("Missing or symlinked build executable")
    if safe_directory(ROOT) != root_identity or safe_directory(dist) != dist_identity:
        raise RuntimeError("Output directory changed during build")

    staging = Path(tempfile.mkdtemp(prefix=".MiniSandbox-build-", dir=dist))
    staging_identity = safe_directory(staging)
    (staging / "Contents/MacOS").mkdir(parents=True)
    (staging / "Contents/Resources").mkdir()
    shutil.copy2(binary, staging / "Contents/MacOS/MiniSandbox")
    os.chmod(staging / "Contents/MacOS/MiniSandbox", 0o755)
    info = {
        "CFBundleExecutable": "MiniSandbox", "CFBundleIdentifier": "dev.mini-sandbox.app",
        "CFBundleName": "Mini Sandbox", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication"
    }
    with (staging / "Contents/Info.plist").open("xb") as stream:
        plistlib.dump(info, stream)
    (staging / "Contents/Resources" / MARKER).write_text(json.dumps(ownership(app), sort_keys=True))
    # Launch Services needs traversal; group/world write remains prohibited.
    os.chmod(staging, 0o755)
    run("codesign", "--force", "--sign", args.sign_identity, str(staging))
    run("codesign", "--verify", "--strict", "--verbose=2", str(staging))
    if safe_directory(ROOT) != root_identity or safe_directory(dist) != dist_identity or safe_directory(staging) != staging_identity:
        raise RuntimeError("Output directory changed while signing; staged bundle preserved")
    if check_existing(app) != previous_identity:
        raise RuntimeError("Existing output changed while building; bundles preserved")

    # Keep the previous bundle rather than recursively deleting it. This is a local
    # build safety check, not protection from an attacker controlling the same UID.
    backup = None
    if previous_identity is not None:
        backup_folder = Path(tempfile.mkdtemp(prefix=".MiniSandbox-backup-", dir=dist))
        backup = backup_folder / "MiniSandbox.app"
        app.rename(backup)
    try:
        if os.path.lexists(app):
            raise RuntimeError("Output path appeared before promotion; bundles preserved")
        staging.rename(app)
    except Exception:
        if backup is not None and not os.path.lexists(app):
            backup.rename(app)
        raise
    digest = hashlib.sha256((app / "Contents/MacOS/MiniSandbox").read_bytes()).hexdigest()
    print(json.dumps({"app": str(app), "executable_sha256": digest,
                      "previous_bundle": str(backup) if backup else None,
                      "signing": "ad-hoc-local-only" if args.sign_identity == "-" else "specified-identity",
                      "notarized": False}, indent=2))


if __name__ == "__main__":
    main()
