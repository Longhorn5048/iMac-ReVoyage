"""Filesystem-only regression: never operates on real services or credentials."""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

HELPER = str(Path(sys.argv.pop(1)).resolve())


class UninstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="revoyage-uninstall-test-")
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def file(self, relative, text="fixture"):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def app(self, name, identifier):
        path = self.home / "Applications/iMac ReVoyage" / name
        (path / "Contents").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "fixture"
        }))
        return path

    def run_helper(self, role, apply=True, extra=()):
        return subprocess.run([HELPER, "--role", role, "--test-root", str(self.home),
                               *(["--apply"] if apply else []), *extra],
                              capture_output=True, text=True, timeout=10)

    def test_dry_run_keeps_everything(self):
        app = self.app("iMac ReVoyage Sender.app", "com.targetbridge.sender")
        result = self.run_helper("sender", apply=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["role"], "sender")
        self.assertTrue(app.exists())

    def test_sender_removes_only_its_role_and_preserves_storage(self):
        sender = self.app("iMac ReVoyage Sender.app", "com.targetbridge.sender")
        receiver = self.app("iMac ReVoyage Receiver.app", "re.voyage.receiver")
        removed = [self.file(p) for p in [
            "Library/Application Support/TargetBridge/settings.json",
            "Library/Preferences/com.targetbridge.sender.plist",
            "Library/Preferences/ByHost/com.targetbridge.sender.host.plist",
            "Library/Caches/com.targetbridge.sender/cache",
            "Library/Saved Application State/com.targetbridge.sender.savedState/state"]]
        retained = [self.file(p) for p in [
            "Library/Preferences/com.targetbridge.sender-other.plist",
            "Library/Preferences/re.voyage.receiver.plist",
            "Library/Application Support/ReVoyage/user-file",
            "ReVoyageStorage/valuable.txt"]]
        result = self.run_helper("sender")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sender.exists())
        self.assertTrue(receiver.exists())
        self.assertTrue(all(not p.exists() for p in removed))
        self.assertTrue(all(p.exists() for p in retained))

    def test_sender_removes_current_install_and_owned_update_backup(self):
        for name in ["iMac ReVoyage Sender.app", ".ReVoyage-Sender-previous.app.backup"]:
            path = self.app(name, "com.targetbridge.sender")
            path.rename(self.home / "Applications" / name)
        result = self.run_helper("sender")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / "Applications/iMac ReVoyage Sender.app").exists())
        self.assertFalse((self.home / "Applications/.ReVoyage-Sender-previous.app.backup").exists())

    def test_sender_preserves_foreign_backup_and_receiver_preserves_sender_backup(self):
        for identifier, role in [("example.foreign", "sender"), ("com.targetbridge.sender", "receiver")]:
            path = self.app(".ReVoyage-Sender-previous.app.backup", identifier)
            backup = self.home / "Applications/.ReVoyage-Sender-previous.app.backup"
            path.rename(backup)
            result = self.run_helper(role)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(backup.exists())
            path.parent.mkdir(parents=True, exist_ok=True)
            backup.rename(path)
            (path / "Contents/Info.plist").unlink()
            (path / "Contents").rmdir()
            path.rmdir()

    def test_receiver_keeps_sender_foreign_apps_logs_and_storage(self):
        receiver = self.app("iMac ReVoyage Receiver.app", "re.voyage.receiver")
        sender = self.app("iMac ReVoyage Sender.app", "com.targetbridge.sender")
        foreign = self.app("iMac ReVoyage Rescue.app", "example.foreign")
        removed = [self.file(p) for p in [
            "Library/LaunchAgents/re.voyage.receiver.plist",
            "Library/LaunchAgents/re.voyage.updater.plist",
            "Library/Logs/iMac ReVoyage/updater.out.log",
            "Library/Logs/iMac ReVoyage/updater.err.log",
            "Library/Logs/iMac ReVoyage/updater-install.log",
            "Library/Application Support/TargetBridge Receiver/Updates/last-update.json",
            "Library/Application Support/TargetBridge Receiver/Updates/fixture/update.zip",
            "Library/Logs/iMac ReVoyage/network.out.log",
            "Library/Application Support/ReVoyage/storage-share-path",
            "Library/Preferences/re.voyage.receiver.plist"]]
        retained = [self.file(p) for p in [
            "Library/Logs/iMac ReVoyage/other-project.log",
            "Library/LaunchAgents/example.foreign.plist",
            "ReVoyageStorage/valuable.txt"]]
        result = self.run_helper("receiver")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(receiver.exists())
        self.assertTrue(sender.exists() and foreign.exists())
        self.assertTrue(all(not p.exists() for p in removed))
        self.assertTrue(all(p.exists() for p in retained))
        self.assertFalse((self.home / "Library/Application Support/ReVoyage").exists())

    def test_symlink_ancestor_cannot_escape_test_home(self):
        outside = self.root / "outside"
        outside.mkdir()
        valuable = outside / "com.targetbridge.sender.plist"
        valuable.write_text("keep")
        (self.home / "Library").mkdir()
        (self.home / "Library/Preferences").symlink_to(outside, target_is_directory=True)
        result = self.run_helper("sender")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(valuable.read_text(), "keep")

    def test_symlink_leaf_removes_link_only(self):
        valuable = self.root / "valuable"
        valuable.write_text("keep")
        leaf = self.home / "Library/Preferences/com.targetbridge.sender.plist"
        leaf.parent.mkdir(parents=True)
        leaf.symlink_to(valuable)
        result = self.run_helper("sender")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(leaf.is_symlink())
        self.assertEqual(valuable.read_text(), "keep")

    def test_outside_app_is_preserved_in_test_mode(self):
        app = self.root / "outside.app"
        (app / "Contents").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.targetbridge.sender"}))
        result = self.run_helper("sender", extra=["--app", str(app)])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(app.exists())

    def test_second_uninstall_is_idempotent(self):
        self.app("iMac ReVoyage Receiver.app", "re.voyage.receiver")
        for _ in range(2):
            result = self.run_helper("receiver")
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_owned_audio_driver_is_removed_without_touching_other_drivers(self):
        driver = self.home / "System/Library/Audio/Plug-Ins/HAL/ReVoyageMicrophone.driver"
        (driver / "Contents").mkdir(parents=True)
        (driver / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.targetbridge.sender.microphone"}))
        foreign = self.file("System/Library/Audio/Plug-Ins/HAL/Other.driver/Contents/valuable")
        result = self.run_helper("sender")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(driver.exists())
        self.assertTrue(foreign.exists())

    def test_speaker_uninstall_preserves_physical_outputs_and_foreign_drivers(self):
        speaker = self.home / "System/Library/Audio/Plug-Ins/HAL/ReVoyageSpeaker.driver"
        (speaker / "Contents").mkdir(parents=True)
        (speaker / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.targetbridge.sender.speaker"}))
        foreign = self.file("System/Library/Audio/Plug-Ins/HAL/BuiltIn.driver/Contents/valuable")
        result = self.run_helper("sender")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(speaker.exists())
        self.assertTrue(foreign.exists())

    def test_foreign_speaker_bundle_is_not_removed(self):
        sender = self.app("iMac ReVoyage Sender.app", "com.targetbridge.sender")
        speaker = self.home / "System/Library/Audio/Plug-Ins/HAL/ReVoyageSpeaker.driver"
        (speaker / "Contents").mkdir(parents=True)
        (speaker / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.foreign"}))
        result = self.run_helper("sender")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(speaker.exists() and sender.exists())

    def test_foreign_audio_driver_keeps_sender_available_for_retry(self):
        sender = self.app("iMac ReVoyage Sender.app", "com.targetbridge.sender")
        driver = self.home / "System/Library/Audio/Plug-Ins/HAL/ReVoyageMicrophone.driver"
        (driver / "Contents").mkdir(parents=True)
        (driver / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "example.foreign"}))
        result = self.run_helper("sender")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(driver.exists() and sender.exists())

    def test_missing_or_invalid_role_is_rejected_before_any_cleanup(self):
        for arguments in [[], ["--role"], ["--role", "invalid"]]:
            result = subprocess.run([HELPER, *arguments], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 64)

    def test_gui_and_unsafe_test_root_are_rejected(self):
        self.assertEqual(self.run_helper("sender", extra=["--gui"]).returncode, 64)
        for path in ["/", "/Users", str(Path.home())]:
            result = subprocess.run([HELPER, "--role", "sender", "--test-root", path, "--apply"],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 64)


if __name__ == "__main__":
    unittest.main()
