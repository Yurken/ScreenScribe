import importlib.util
import json
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("screenscribe_signing", Path(__file__).resolve().parents[1] / "signing.py")
signing = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = signing
SPEC.loader.exec_module(signing)

FIRST = signing.Identity("A" * 40, "Apple Development: Test One (TEAMONE)")
SECOND = signing.Identity("B" * 40, "Apple Development: Test Two (TEAMTWO)")
REQUIREMENT = 'identifier "com.yurken.screenscribe" and anchor apple generic and certificate leaf[subject.CN] = "Test One"'
STABLE = signing.Signature(REQUIREMENT, False, FIRST.name)
ADHOC = signing.Signature('cdhash H"1234"', True)


def create_app(path, version="1", identifier=signing.BUNDLE_ID):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/MacOS/ScreenScribe").write_bytes(b"test executable")
    with (path / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": "ScreenScribe", "CFBundleVersion": version}, stream)
    return path


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "private/signing.json"

    def test_parse_only_valid_identity_rows(self):
        output = '  1) ' + FIRST.sha1 + ' "' + FIRST.name + '"\n     1 valid identities found\n'
        self.assertEqual(signing.parse_identities(output), [FIRST])

    def test_first_selection_pins_and_reuses_certificate_when_another_appears(self):
        self.assertEqual(signing.choose_identity([FIRST], self.config), FIRST)
        self.assertEqual(signing.choose_identity([FIRST, SECOND], self.config), FIRST)
        self.assertEqual(json.loads(self.config.read_text())["sha1"], FIRST.sha1)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)

    def test_installed_identity_is_preferred_over_unrelated_certificate(self):
        selected = signing.choose_identity([FIRST, SECOND], self.config, installed_authority=SECOND.name)
        self.assertEqual(selected, SECOND)

    def test_missing_pinned_certificate_never_falls_back_even_in_ci(self):
        signing.save_identity(self.config, FIRST)
        before = self.config.read_bytes()
        with patch.dict(os.environ, {"CI": "true"}), self.assertRaisesRegex(signing.SigningError, "Refusing to fall back"):
            signing.choose_identity([SECOND], self.config)
        self.assertEqual(self.config.read_bytes(), before)

    def test_missing_or_ambiguous_certificate_requires_configuration(self):
        for identities in ([], [FIRST, SECOND]):
            with self.assertRaises(signing.SigningError):
                signing.choose_identity(identities, self.config)
        self.assertFalse(self.config.exists())

    def test_invalid_configuration_is_not_silently_replaced(self):
        self.config.parent.mkdir()
        self.config.write_text('{"version":1,"sha1":"invalid"}')
        with self.assertRaisesRegex(signing.SigningError, "Invalid local"):
            signing.choose_identity([FIRST], self.config)

    def test_explicit_ci_ad_hoc_does_not_overwrite_personal_pin(self):
        signing.save_identity(self.config, FIRST)
        before = self.config.read_bytes()
        self.assertIsNone(signing.choose_identity([], self.config, requested="-"))
        self.assertEqual(self.config.read_bytes(), before)

    def test_explicit_selection_does_not_change_default_pin(self):
        signing.save_identity(self.config, FIRST)
        self.assertEqual(signing.choose_identity([FIRST, SECOND], self.config, requested=SECOND.sha1), SECOND)
        self.assertEqual(signing.choose_identity([FIRST, SECOND], self.config), FIRST)

    def test_ambiguous_name_is_rejected(self):
        duplicate = signing.Identity(SECOND.sha1, FIRST.name)
        with self.assertRaises(signing.SigningError):
            signing.choose_identity([FIRST, duplicate], self.config, requested=FIRST.name)


class ContinuityTests(unittest.TestCase):
    def test_legacy_ad_hoc_implicit_requirement_is_recognized_for_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(Path(directory) / "ScreenScribe.app")
            outputs = ["", "Signature=adhoc\nTeamIdentifier=not set\n", 'Executable=test\n# designated => cdhash H"1234"\n']
            with patch.object(signing, "run", side_effect=outputs):
                self.assertEqual(signing.inspect_signature(app), ADHOC)

    def test_first_install_requires_stable_signature(self):
        self.assertFalse(signing.validate_update(None, STABLE))
        with self.assertRaisesRegex(signing.SigningError, "ad-hoc update"):
            signing.validate_update(None, ADHOC, allow_identity_change=True)

    def test_ad_hoc_downgrade_is_always_refused(self):
        for migration in (False, True):
            with self.assertRaises(signing.SigningError):
                signing.validate_update(STABLE, ADHOC, migration)

    def test_migration_is_explicit_and_same_identity_does_not_need_it(self):
        self.assertFalse(signing.validate_update(STABLE, STABLE))
        with self.assertRaisesRegex(signing.SigningError, "--migrate-signing"):
            signing.validate_update(ADHOC, STABLE)
        self.assertTrue(signing.validate_update(ADHOC, STABLE, True))
        other = signing.Signature('identifier "com.yurken.screenscribe" and certificate leaf[subject.CN] = "Other"', False, SECOND.name)
        with self.assertRaises(signing.SigningError):
            signing.validate_update(STABLE, other)

    def test_matching_text_is_also_verified_cryptographically_both_ways(self):
        with tempfile.TemporaryDirectory() as directory:
            installed = Path(directory) / "ScreenScribe.app"
            installed.mkdir()
            with patch.object(signing, "inspect_signature", return_value=STABLE), patch.object(signing, "run") as run:
                self.assertFalse(signing.check_update(installed, Path(directory) / "new.app"))
                self.assertEqual(run.call_count, 2)
                for call in run.call_args_list:
                    self.assertIn("-R=" + REQUIREMENT, call.args)

    def test_invalid_signature_cannot_pass_by_matching_requirement_text(self):
        with tempfile.TemporaryDirectory() as directory:
            installed = Path(directory) / "ScreenScribe.app"
            installed.mkdir()
            with patch.object(signing, "inspect_signature", return_value=STABLE), patch.object(signing, "run", side_effect=signing.SigningError("invalid certificate")):
                with self.assertRaisesRegex(signing.SigningError, "invalid certificate"):
                    signing.check_update(installed, Path(directory) / "new.app")

    def test_wrong_app_identifier_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            app = create_app(Path(directory) / "Wrong.app", identifier="example.wrong")
            with self.assertRaises(signing.SigningError):
                signing.app_info(app)


class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.source = create_app(root / "source/ScreenScribe.app", "new")
        self.destination = create_app(root / "Applications/ScreenScribe.app", "old")
        self.backups = root / "backups"

    @staticmethod
    def fake_ditto(*args):
        if "-c" in args:
            Path(args[-1]).write_bytes(b"rollback archive")
        else:
            shutil.copytree(args[-2], args[-1])
        return ""

    def version(self):
        with (self.destination / "Contents/Info.plist").open("rb") as stream:
            return plistlib.load(stream)["CFBundleVersion"]

    def test_running_application_is_not_overwritten(self):
        with patch.object(signing, "check_update"), patch.object(signing, "require_stopped", side_effect=signing.SigningError("Quit ScreenScribe")), patch.object(signing, "run") as run:
            with self.assertRaises(signing.SigningError):
                signing.install_app(self.source, self.destination, backup_dir=self.backups)
            run.assert_not_called()
        self.assertEqual(self.version(), "old")

    def test_success_preserves_archive_and_leaves_no_partial_staging(self):
        with patch.object(signing, "check_update"), patch.object(signing, "require_stopped"), patch.object(signing, "inspect_signature", return_value=STABLE), patch.object(signing, "run", side_effect=self.fake_ditto):
            signing.install_app(self.source, self.destination, backup_dir=self.backups)
        self.assertEqual(self.version(), "new")
        self.assertEqual(len(list(self.backups.glob("*.zip"))), 1)
        self.assertEqual(list(self.destination.parent.glob(".screenscribe-install-*")), [])

    def test_copy_failure_keeps_previous_app(self):
        with patch.object(signing, "check_update"), patch.object(signing, "require_stopped"), patch.object(signing, "run", side_effect=signing.SigningError("copy failed")):
            with self.assertRaisesRegex(signing.SigningError, "copy failed"):
                signing.install_app(self.source, self.destination, backup_dir=self.backups)
        self.assertEqual(self.version(), "old")

    def test_post_install_validation_failure_rolls_back(self):
        with patch.object(signing, "check_update"), patch.object(signing, "require_stopped"), patch.object(signing, "run", side_effect=self.fake_ditto), patch.object(signing, "inspect_signature", side_effect=signing.SigningError("verification failed")):
            with self.assertRaisesRegex(signing.SigningError, "verification failed"):
                signing.install_app(self.source, self.destination, backup_dir=self.backups)
        self.assertEqual(self.version(), "old")
        self.assertEqual(len(list(self.backups.glob("*.zip"))), 1)


if __name__ == "__main__":
    unittest.main()
