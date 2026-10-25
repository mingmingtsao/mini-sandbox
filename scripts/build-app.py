#!/usr/bin/env python3
"""Build a locally runnable macOS app; never recursively delete output paths."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MARKER = ".mini-sandbox-owner"
ENTITLEMENTS = Path(__file__).with_name("app.entitlements")
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
VARIANTS = {
    "release": {"app": "MiniSandbox.app", "bundle_id": "dev.mini-sandbox.app", "name": "Mini Sandbox"},
    # Test-only composition: fixed 127.0.0.1 scripted provider, never Keychain.
    "local-fixture": {
        "app": "MiniSandboxFixture.app",
        "bundle_id": "dev.mini-sandbox.app.local-fixture",
        "name": "Mini Sandbox Local Fixture",
    },
}


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


def read_version() -> str:
    """Single source of truth for CFBundleShortVersionString: the VERSION file."""
    path = ROOT / "VERSION"
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > 64:
            raise RuntimeError("Unsafe VERSION file: " + str(path))
        version = path.read_text().strip()
    except OSError as error:
        raise RuntimeError("Missing VERSION file: " + str(path)) from error
    if not VERSION_PATTERN.fullmatch(version):
        raise RuntimeError("VERSION must be MAJOR.MINOR.PATCH: " + repr(version))
    return version


def build_number(value: str) -> int:
    if not (value.isascii() and value.isdigit()) or int(value) < 1:
        raise argparse.ArgumentTypeError("build number must be a positive integer")
    return int(value)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=("debug", "release"), default="release")
    parser.add_argument("--sign-identity", default="-", help="codesign identity; default is local ad-hoc signing")
    parser.add_argument("--build-number", type=build_number, default=1, help="CFBundleVersion; default 1")
    parser.add_argument(
        "--test-fixtures",
        action="store_true",
        help="build the SANDBOX_TEST_FIXTURES local-fixture app into dist/MiniSandboxFixture.app",
    )
    args = parser.parse_args()
    variant_name = "local-fixture" if args.test_fixtures else "release"
    variant = VARIANTS[variant_name]
    version = read_version()
    # The fixture define changes compiled code, so it must never share build products.
    build_args = ["--build-path", str(ROOT / ".build/fixtures")] if args.test_fixtures else []
    define_args = ["-Xswiftc", "-DSANDBOX_TEST_FIXTURES"] if args.test_fixtures else []
    root_identity = safe_directory(ROOT)
    dist = ROOT / "dist"
    if not os.path.lexists(dist):
        dist.mkdir(mode=0o755)
    dist_identity = safe_directory(dist)
    app = dist / variant["app"]
    previous_identity = check_existing(app)

    run("swift", "build", "-c", args.configuration, *build_args, *define_args, "--product", "MiniSandbox")
    bin_path = Path(
        subprocess.check_output(
            ["swift", "build", "-c", args.configuration, *build_args, "--show-bin-path"], cwd=ROOT, text=True
        ).strip()
    )
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
        "CFBundleExecutable": "MiniSandbox",
        "CFBundleIdentifier": variant["bundle_id"],
        "CFBundleName": variant["name"],
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(args.build_number),
        "LSMinimumSystemVersion": "14.0",
        "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }
    with (staging / "Contents/Info.plist").open("xb") as stream:
        plistlib.dump(info, stream)
    (staging / "Contents/Resources" / MARKER).write_text(json.dumps(ownership(app), sort_keys=True))
    # Launch Services needs traversal; group/world write remains prohibited.
    os.chmod(staging, 0o755)
    run("codesign", "--force", "--sign", args.sign_identity, "--entitlements", str(ENTITLEMENTS), str(staging))
    run("codesign", "--verify", "--strict", "--verbose=2", str(staging))
    if (
        safe_directory(ROOT) != root_identity
        or safe_directory(dist) != dist_identity
        or safe_directory(staging) != staging_identity
    ):
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
    print(
        json.dumps(
            {
                "app": str(app),
                "executable_sha256": digest,
                "variant": variant_name,
                "bundle_identifier": variant["bundle_id"],
                "version": version,
                "build_number": args.build_number,
                "previous_bundle": str(backup) if backup else None,
                "signing": "ad-hoc-local-only" if args.sign_identity == "-" else "specified-identity",
                "notarized": False,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
