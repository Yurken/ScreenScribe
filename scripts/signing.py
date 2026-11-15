#!/usr/bin/env python3
"""Stable local signing and guarded installation; never edits macOS privacy grants."""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "com.yurken.screenscribe"
SUPPORT = Path.home() / "Library/Application Support/ScreenScribe"
DEFAULT_DESTINATION = Path("/Applications/ScreenScribe.app")


class SigningError(RuntimeError):
    pass


@dataclass(frozen=True)
class Identity:
    sha1: str
    name: str


@dataclass(frozen=True)
class Signature:
    requirement: str
    adhoc: bool
    authority: str = ""


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise SigningError(result.stderr.strip() or result.stdout.strip() or "Command failed: " + str(args[0]))
    return result.stdout + result.stderr


def parse_identities(output):
    return [Identity(sha.upper(), name) for sha, name in re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"', output, re.MULTILINE)]


def config_path():
    return Path(os.environ.get("SCREENSCRIBE_SIGNING_CONFIG", str(SUPPORT / "signing.json"))).expanduser()


def save_identity(path, identity):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".signing-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump({"version": 1, "sha1": identity.sha1, "name": identity.name}, stream, indent=2)
            stream.write("\n")
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def choose_identity(identities, path, requested=None, installed_authority=""):
    if requested == "-":
        return None  # Only an explicit request can produce an ad-hoc build.
    if requested:
        matches = [item for item in identities if item.sha1 == requested.upper() or item.name == requested]
        if len(matches) != 1:
            raise SigningError("The requested signing identity is missing or ambiguous. Use its full certificate SHA-1.")
        return matches[0]
    if path.exists():
        try:
            pinned = json.loads(path.read_text())
            sha = pinned["sha1"]
            if pinned.get("version") != 1 or not re.fullmatch(r"[0-9A-Fa-f]{40}", sha):
                raise ValueError("invalid configuration")
        except (ValueError, KeyError, TypeError) as error:
            raise SigningError("Invalid local signing configuration: " + str(path)) from error
        matches = [item for item in identities if item.sha1 == sha.upper()]
        if len(matches) != 1:
            raise SigningError("The pinned signing certificate is unavailable. Restore/unlock it or explicitly configure a replacement. Refusing to fall back to ad-hoc signing.")
        return matches[0]
    candidates = [item for item in identities if item.name.startswith(("Apple Development:", "Mac Developer:", "Developer ID Application:"))]
    installed = [item for item in candidates if item.name == installed_authority]
    if len(installed) == 1:
        candidates = installed
    if len(candidates) != 1:
        raise SigningError("No unique stable signing identity was found. Run 'security find-identity -v -p codesigning', then 'python3 scripts/signing.py configure --identity <SHA1>'. Ad-hoc signing is never selected automatically.")
    save_identity(path, candidates[0])
    return candidates[0]


def app_info(app):
    app = Path(app)
    if app.is_symlink():
        raise SigningError("Refusing a symlink app bundle: " + str(app))
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SigningError("Invalid app bundle: " + str(app)) from error
    executable = info.get("CFBundleExecutable", "")
    if info.get("CFBundleIdentifier") != BUNDLE_ID or not executable or Path(executable).name != executable:
        raise SigningError("Expected a ScreenScribe app with its original bundle identifier and executable name.")
    if not (app / "Contents/MacOS" / executable).is_file():
        raise SigningError("App executable is missing: " + str(app))
    return info


def inspect_signature(app):
    app_info(app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    details = run("/usr/bin/codesign", "-d", "--verbose=4", app)
    requirements = run("/usr/bin/codesign", "-d", "-r-", app)
    match = re.search(r"^(?:#\s*)?designated => (.+)$", requirements, re.MULTILINE)
    if not match:
        raise SigningError("App has no designated requirement: " + str(app))
    authority = re.search(r"^Authority=(.+)$", details, re.MULTILINE)
    return Signature(match.group(1), "Signature=adhoc" in details,
                     authority.group(1) if authority else "")


def sign_app(app, requested=None):
    app = Path(app)
    app_info(app)
    # Do not consult the keychain at all for explicitly requested CI test builds.
    if requested == "-":
        identity = None
    else:
        identities = parse_identities(run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"))
        installed_authority = ""
        if DEFAULT_DESTINATION.exists() and not config_path().exists() and not requested:
            installed_authority = inspect_signature(DEFAULT_DESTINATION).authority
        identity = choose_identity(identities, config_path(), requested, installed_authority)
    args = ["/usr/bin/codesign", "--force", "--entitlements", ROOT / "Resources/ScreenScribe.entitlements"]
    if identity:
        args += ["--options", "runtime", "--timestamp" if identity.name.startswith("Developer ID Application:") else "--timestamp=none", "--sign", identity.sha1]
    else:
        print("Explicit ad-hoc TEST build: privacy permissions will not persist across rebuilds.", file=sys.stderr)
        args += ["--sign", "-"]
    run(*(args + [app]))
    signature = inspect_signature(app)
    if identity and (signature.adhoc or not signature.authority):
        raise SigningError("Stable certificate signing failed.")
    print("Signed with " + ("a stable certificate identity." if identity else "an explicit ad-hoc test identity."))
    return signature


def validate_update(old, new, allow_identity_change=False):
    if new.adhoc or not new.authority:
        raise SigningError("Local installation requires certificate signing. Refusing an ad-hoc update that would lose privacy permissions; build locally with scripts/build.sh first.")
    changed = old is not None and (old.adhoc or old.requirement != new.requirement)
    if changed and not allow_identity_change:
        raise SigningError("Signing identity changed. Update refused to protect existing privacy permissions. Use --migrate-signing only for an intentional one-time identity migration.")
    return changed


def check_update(installed, app, allow_identity_change=False):
    new = inspect_signature(app)
    old = inspect_signature(installed) if Path(installed).exists() else None
    changed = validate_update(old, new, allow_identity_change)
    if old and not changed:
        # Test cryptographic requirements, rather than trusting matching text alone.
        run("/usr/bin/codesign", "--verify", "--strict", "-R=" + old.requirement, app)
        run("/usr/bin/codesign", "--verify", "--strict", "-R=" + new.requirement, installed)
    if changed:
        print("Intentional signing migration: macOS may require one final privacy grant for this new identity.")
    else:
        print("Signing continuity verified.")
    return changed


def require_stopped(app):
    if not Path(app).exists():
        return
    executable = Path(app) / "Contents/MacOS" / app_info(app)["CFBundleExecutable"]
    pattern = "^" + re.escape(str(executable)) + "([[:space:]]|$)"
    result = subprocess.run(["/usr/bin/pgrep", "-f", pattern], capture_output=True, text=True)
    if result.returncode == 0:
        raise SigningError("Quit ScreenScribe before updating so drawings and active recordings can be saved.")
    if result.returncode != 1:
        raise SigningError("Unable to verify that ScreenScribe has stopped; installation was not changed.")


def install_app(source, destination, allow_identity_change=False, backup_dir=None):
    source, destination = Path(source).absolute(), Path(destination).absolute()
    if source == destination or destination.name != "ScreenScribe.app" or destination.is_symlink():
        raise SigningError("Invalid installation destination.")
    check_update(destination, source, allow_identity_change)
    require_stopped(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".screenscribe-install-", dir=str(destination.parent)))
    previous = staging / "previous.app"
    preserve_staging = False
    try:
        candidate = staging / "ScreenScribe.app"
        run("/usr/bin/ditto", "--norsrc", "--noextattr", source, candidate)
        check_update(destination, candidate, allow_identity_change)
        require_stopped(destination)
        if destination.exists():
            backups = Path(backup_dir) if backup_dir else SUPPORT / "backups"
            backups.mkdir(parents=True, exist_ok=True, mode=0o700)
            archive = backups / ("ScreenScribe-" + uuid.uuid4().hex + ".zip")
            run("/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--keepParent", destination, archive)
            print("Rollback archive: " + str(archive))
            destination.rename(previous)
        try:
            candidate.rename(destination)
            inspect_signature(destination)
        except Exception:
            if destination.exists():
                destination.rename(staging / "failed.app")
            if previous.exists():
                try:
                    previous.rename(destination)
                except OSError:
                    preserve_staging = True
                    print("Rollback needs attention; preserved previous app at " + str(previous), file=sys.stderr)
                    raise
            raise
    finally:
        if not preserve_staging:
            shutil.rmtree(staging)
    print("Installed: " + str(destination))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    sign = commands.add_parser("sign")
    sign.add_argument("app", type=Path)
    sign.add_argument("--identity", default=os.environ.get("SCREENSCRIBE_SIGNING_IDENTITY"))
    configure = commands.add_parser("configure")
    configure.add_argument("--identity", required=True)
    for name in ("check-update", "install"):
        command = commands.add_parser(name)
        command.add_argument("--app", type=Path, default=ROOT / "dist/ScreenScribe.app")
        command.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION)
        command.add_argument("--migrate-signing", action="store_true")
        if name == "install":
            command.add_argument("--backup-dir", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "sign":
            sign_app(args.app, args.identity)
        elif args.command == "configure":
            identities = parse_identities(run("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"))
            identity = choose_identity(identities, config_path(), args.identity)
            if identity is None:
                raise SigningError("Cannot pin an ad-hoc identity.")
            save_identity(config_path(), identity)
            print("Pinned stable signing identity in " + str(config_path()))
        elif args.command == "check-update":
            check_update(args.destination, args.app, args.migrate_signing)
        else:
            install_app(args.app, args.destination, args.migrate_signing, args.backup_dir)
    except (SigningError, OSError) as error:
        parser.exit(1, "Signing/install error: " + str(error) + "\n")


if __name__ == "__main__":
    main()
