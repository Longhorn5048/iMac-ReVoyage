"""Installer fixture mode: copies under a temporary root; services must stay untouched."""
import os
import json
import sys
from pathlib import Path
import plistlib
import shutil
import shlex
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/install_receiver.command"


class ReceiverInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="revoyage-install-test-")
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.package = self.root / "package"
        self.package.mkdir()
        shutil.copy(SCRIPT, self.package / SCRIPT.name)
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        sentinel = self.fakebin / "launchctl"
        sentinel.write_text('#!/bin/sh\ntouch "$REVOYAGE_TEST_SERVICE_MARKER"\necho "Service operation forbidden in fixture mode" >&2\nexit 99\n')
        sentinel.chmod(0o755)
        self.environment = {**os.environ, "REVOYAGE_DRY_RUN": "1", "REVOYAGE_TEST_SERVICE_MARKER": str(self.root / "service-called"),
                            "PATH": str(self.fakebin) + ":" + os.environ["PATH"]}

    def tearDown(self):
        self.temporary.cleanup()

    def app(self, name):
        app = self.package / ("iMac ReVoyage " + name + ".app") / "Contents/MacOS"
        app.mkdir(parents=True)
        (app / "fixture").write_text("fixture")
        executable = {"Receiver": "TargetBridgeReceiver", "Rescue": "RescueReceiver", "Storage Watcher": "StorageWatcher", "Media Bridge": "ReVoyageMediaBridge"}[name]
        (app / executable).write_text("#!/bin/sh\nexit 0\n")
        (app / executable).chmod(0o755)

    def run_installer(self, root=None, dry=True):
        environment = dict(self.environment)
        if not dry:
            environment["REVOYAGE_DRY_RUN"] = "0"
        return subprocess.run(["/bin/zsh", str(self.package / SCRIPT.name), "--test-root", str(root or self.home)],
                              env=environment, capture_output=True, text=True, timeout=15)

    def test_new_package_creates_four_agents_without_service_operations(self):
        for name in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"):
            self.app(name)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "service-called").exists())
        agents = list((self.home / "Library/LaunchAgents").glob("*.plist"))
        self.assertEqual(len(agents), 4)
        for agent in agents:
            info = plistlib.loads(agent.read_bytes())
            self.assertTrue(Path(info["ProgramArguments"][0]).is_relative_to(self.home))
            stem = info["Label"].split(".")[-1]
            if stem == "receiver": stem = "network"
            self.assertEqual(Path(info["StandardErrorPath"]).name, stem + ".err.log")
        self.assertFalse((self.home / "Library/Application Support").exists())

    def test_historical_package_does_not_create_media_agent(self):
        for name in ("Receiver", "Rescue", "Storage Watcher"):
            self.app(name)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.home / "Library/LaunchAgents").glob("*.plist"))), 3)

    def add_updater(self):
        helper = self.package / "iMac ReVoyage Receiver.app/Contents/MacOS/ReVoyageReceiverUpdater"
        helper.write_text("#!/bin/sh\nexit 0\n")
        helper.chmod(0o755)

    def test_update_capable_package_adds_independent_updater_agent(self):
        for name in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"): self.app(name)
        self.add_updater()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        agents = self.home / "Library/LaunchAgents"
        self.assertEqual(len(list(agents.glob("*.plist"))), 5)
        info = plistlib.loads((agents / "re.voyage.updater.plist").read_bytes())
        self.assertEqual(info["ProgramArguments"], [str(self.home / "Applications/iMac ReVoyage/iMac ReVoyage Receiver.app/Contents/MacOS/ReVoyageReceiverUpdater")])
        self.assertTrue(info["KeepAlive"] and info["RunAtLoad"])
        self.assertFalse((self.root / "service-called").exists())

    def test_remote_transaction_keeps_updater_alive_including_rollback(self):
        for should_fail in (False, True):
            with self.subTest(should_fail=should_fail):
                if (self.home / "Applications").exists(): shutil.rmtree(self.home / "Applications")
                if (self.home / "Library").exists(): shutil.rmtree(self.home / "Library")
                target, agents = self.install_old()
                old_updater = plistlib.dumps({"Label":"re.voyage.updater", "Old":True})
                (agents / "re.voyage.updater.plist").write_bytes(old_updater)
                for name in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"):
                    if not (self.package / ("iMac ReVoyage " + name + ".app")).exists(): self.app(name)
                self.add_updater()
                state = self.root / ("state-failed" if should_fail else "state-success")
                state.mkdir()
                labels = ["receiver", "rescue", "storage", "media", "updater"]
                for label in labels: (state / ("re.voyage." + label)).touch()
                # Only this fixture copy enters service branches, which are
                # redirected to a temporary fake launchctl. Real HOME is never used.
                copied = self.package / SCRIPT.name
                copied.write_text(SCRIPT.read_text().replace('"${REVOYAGE_DRY_RUN:-0}" != 1', '"${REVOYAGE_FIXTURE_SERVICES:-0}" == 1').replace("REMOTE_UPDATE=0", "REMOTE_UPDATE=1"))
                codesign = self.fakebin / "codesign"
                codesign.write_text("#!/bin/sh\nexit 0\n"); codesign.chmod(0o755)
                fake = self.fakebin / "launchctl"
                fake.write_text("#!" + sys.executable + "\n" + r'''import json, os, plistlib, sys
from pathlib import Path
state = Path(os.environ["REVOYAGE_SERVICE_STATE"])
command = sys.argv[1]
if command in ("print", "bootout"):
    label = sys.argv[2].split("/")[-1]
    if command == "print": sys.exit(0 if (state / label).exists() else 1)
    (state / label).unlink(missing_ok=True)
else:
    plist = plistlib.loads(Path(sys.argv[3]).read_bytes())
    label = plist["Label"]
    if os.environ["REVOYAGE_FAIL_RESTART"] == "1" and label == "re.voyage.receiver" and not (state / "failed-once").exists():
        (state / "failed-once").touch()
        sys.exit(1)
    (state / label).touch()
with (state / "events.jsonl").open("a") as output: output.write(json.dumps({"command":command,"label":label}) + "\n")
''')
                fake.chmod(0o755)
                self.environment.update(REVOYAGE_FIXTURE_SERVICES="1", REVOYAGE_SERVICE_STATE=str(state), REVOYAGE_FAIL_RESTART="1" if should_fail else "0")
                result = self.run_installer()
                self.assertEqual(result.returncode == 0, not should_fail, result.stderr)
                self.assertTrue(all((state / ("re.voyage." + label)).exists() for label in labels))
                events = [json.loads(line) for line in (state / "events.jsonl").read_text().splitlines()]
                self.assertFalse(any(event["label"] == "re.voyage.updater" for event in events))
                if should_fail:
                    self.assertEqual((agents / "re.voyage.updater.plist").read_bytes(), old_updater)
                    self.assertTrue((target / "iMac ReVoyage Receiver.app/old").exists())

    def test_fixture_cannot_request_real_remote_installation(self):
        result = subprocess.run(["/bin/zsh", str(self.package / SCRIPT.name), "--remote-update"], env=self.environment, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 64)
        self.assertFalse((self.root / "service-called").exists())

    def run_ssh_fixture(self, enabled=False, loaded=False, authorization="success", remote=False, dry=False, install=False):
        # Redirect absolute system tools only in a temporary script copy. Never
        # invoke real systemsetup, osascript, launchctl or open from these tests.
        state = self.root / "ssh-state.json"
        state.write_text(json.dumps({"enabled": enabled, "loaded": loaded, "events": []}))
        source = SCRIPT.read_text()
        for tool in ("launchctl", "osascript", "open", "sleep", "id", "scutil"):
            fake = self.fakebin / ("ssh-" + tool)
            fake.write_text("#!" + sys.executable + "\n" + r'''import json, os, sys
from pathlib import Path
state = Path(os.environ["REVOYAGE_SSH_STATE"])
info = json.loads(state.read_text())
tool = Path(sys.argv[0]).name.removeprefix("ssh-")
info["events"].append({"tool": tool, "arguments": sys.argv[1:]})
result = 0
if tool == "launchctl":
    if sys.argv[1] == "print-disabled":
        print('disabled services = {\n "com.openssh.sshd" => ' + ("enabled" if info["enabled"] else "disabled") + '\n "other.job" => enabled\n}')
    elif sys.argv[1] == "print":
        result = 0 if info["loaded"] else 1
    else: raise AssertionError("Unexpected launchctl mutation")
elif tool == "osascript":
    assert sys.argv[1:] == ["-e", 'do shell script "/usr/sbin/systemsetup -setremotelogin on" with administrator privileges']
    mode = os.environ["REVOYAGE_SSH_AUTHORIZATION"]
    if mode == "success": info.update(enabled=True, loaded=True)
    elif mode == "cancel": result = 1
    else: print("systemsetup: full disk access required")
elif tool == "id": print("receiver-fixture")
elif tool == "scutil": print("iMac-fixture")
state.write_text(json.dumps(info))
sys.exit(result)
''')
            fake.chmod(0o755)
            original = {"launchctl": "/bin/launchctl", "sleep": "/bin/sleep", "scutil": "/usr/sbin/scutil"}.get(tool, "/usr/bin/" + tool)
            source = source.replace(original, shlex.quote(str(fake)))
        if remote: source = source.replace("REMOTE_UPDATE=0", "REMOTE_UPDATE=1")
        if install:
            # Only SSH branches use our fake tools; application installation
            # remains confined to the ordinary filesystem-only fixture root.
            source = source.replace('if [[ "${REVOYAGE_DRY_RUN:-0}" == 1 || "$REMOTE_UPDATE" == 1 ]]; then',
                                    'if [[ "$REMOTE_UPDATE" == 1 ]]; then')
            source = source.replace('if [[ "${REVOYAGE_DRY_RUN:-0}" == 1 ]]; then\n    echo "Dry run:',
                                    'if false; then\n    echo "Dry run:')
        copied = self.package / SCRIPT.name
        copied.write_text(source)
        environment = {**self.environment, "REVOYAGE_DRY_RUN": "1" if dry else "0",
                       "REVOYAGE_SSH_STATE": str(state), "REVOYAGE_SSH_AUTHORIZATION": authorization}
        arguments = ["--test-root", str(self.home)] if install else ["--enable-ssh"]
        result = subprocess.run(["/bin/zsh", str(copied), *arguments], env=environment,
                                capture_output=True, text=True, timeout=10)
        return result, json.loads(state.read_text())["events"]

    def test_ssh_enable_requests_admin_and_verifies_effective_service(self):
        result, events = self.run_ssh_fixture()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SSH 已开启", result.stdout)
        self.assertIn("ssh receiver-fixture@iMac-fixture.local", result.stdout)
        self.assertEqual(sum(e["tool"] == "osascript" for e in events), 1)
        self.assertFalse(any(e["tool"] == "open" for e in events))
        self.assertEqual(list(self.home.iterdir()), [])

    def test_existing_ssh_does_not_request_admin_or_change_user_access(self):
        result, events = self.run_ssh_fixture(enabled=True, loaded=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SSH 已开启", result.stdout)
        self.assertFalse(any(e["tool"] in ("osascript", "open") for e in events))

    def test_ssh_authorization_cancellation_reports_incomplete_state(self):
        result, events = self.run_ssh_fixture(authorization="cancel")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SSH 已开启", result.stdout)
        self.assertIn("管理员授权未完成", result.stderr)
        self.assertIn("--enable-ssh", result.stderr)
        self.assertEqual(sum(e["tool"] == "open" for e in events), 1)

    def test_ssh_successful_exit_without_permission_is_not_reported_as_enabled(self):
        result, _ = self.run_ssh_fixture(authorization="permission-denied")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SSH 已开启", result.stdout)
        self.assertIn("完整磁盘访问权限", result.stderr)

    def test_loaded_but_disabled_ssh_still_requires_enabling(self):
        result, events = self.run_ssh_fixture(enabled=False, loaded=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(e["tool"] == "osascript" for e in events), 1)

    def test_ssh_enabled_override_without_loaded_service_is_not_success(self):
        result, _ = self.run_ssh_fixture(enabled=True, loaded=False, authorization="permission-denied")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SSH 已开启", result.stdout)

    def test_remote_upgrade_and_dry_run_never_request_ssh_authorization(self):
        for options in ({"remote": True}, {"dry": True}):
            with self.subTest(options=options):
                result, events = self.run_ssh_fixture(**options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(events, [])

    def test_ssh_permission_failure_preserves_completed_core_installation(self):
        for app in ("Receiver", "Rescue", "Storage Watcher"): self.app(app)
        result, events = self.run_ssh_fixture(dry=True, install=True, authorization="permission-denied")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("安装完成", result.stdout)
        self.assertIn("SSH 设置未完成", result.stderr)
        target = self.home / "Applications/iMac ReVoyage"
        self.assertTrue((target / "iMac ReVoyage Receiver.app/Contents/MacOS/TargetBridgeReceiver").exists())
        self.assertEqual(len(list((self.home / "Library/LaunchAgents").glob("*.plist"))), 3)
        self.assertEqual(sum(e["tool"] == "osascript" for e in events), 1)

    def install_old(self):
        target = self.home / "Applications/iMac ReVoyage"
        agents = self.home / "Library/LaunchAgents"
        agents.mkdir(parents=True)
        for app, label in (("Receiver", "receiver"), ("Rescue", "rescue"), ("Storage Watcher", "storage"), ("Media Bridge", "media")):
            bundle = target / ("iMac ReVoyage " + app + ".app")
            bundle.mkdir(parents=True)
            (bundle / "old").write_text("old-" + app)
            (agents / ("re.voyage." + label + ".plist")).write_bytes(plistlib.dumps({"Label": "re.voyage." + label, "Old": True}))
        return target, agents

    def fail_tool(self, tool, matching):
        wrapper = self.fakebin / tool
        wrapper.write_text("#!/bin/sh\ncase \"$1\" in " + matching + ") echo 'injected failure' >&2; exit 1;; esac\nexec /bin/" + tool + " \"$@\"\n" if tool == "mv" else
                           "#!/bin/sh\ncase \"$1\" in " + matching + ") echo 'injected failure' >&2; exit 1;; esac\nexec /usr/bin/" + tool + " \"$@\"\n")
        wrapper.chmod(0o755)

    def test_core_staging_failure_preserves_existing_apps_and_plists(self):
        target, agents = self.install_old()
        originals = {p.name: p.read_bytes() for p in agents.glob("*.plist")}
        for app in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"): self.app(app)
        self.fail_tool("ditto", '*"Receiver.app"')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((target / "iMac ReVoyage Rescue.app/old").exists())
        self.assertEqual(originals, {p.name: p.read_bytes() for p in agents.glob("*.plist")})
        self.assertFalse((self.root / "service-called").exists())

    def test_incomplete_bundle_is_rejected_before_touching_old_installation(self):
        target, agents = self.install_old()
        for app in ("Receiver", "Rescue", "Storage Watcher"): self.app(app)
        (self.package / "iMac ReVoyage Rescue.app/Contents/MacOS/RescueReceiver").unlink()
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((target / "iMac ReVoyage Rescue.app/old").exists())
        self.assertFalse((self.root / "service-called").exists())

    def test_core_commit_failure_restores_previously_replaced_rescue(self):
        target, agents = self.install_old()
        originals = {p.name: p.read_bytes() for p in agents.glob("*.plist")}
        for app in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"): self.app(app)
        self.fail_tool("mv", '*"/apps/iMac ReVoyage Receiver.app"')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        for app in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"):
            self.assertEqual((target / ("iMac ReVoyage " + app + ".app") / "old").read_text(), "old-" + app)
        self.assertEqual(originals, {p.name: p.read_bytes() for p in agents.glob("*.plist")})
        self.assertFalse(list(target.glob(".install.*")))

    def test_optional_media_failure_preserves_core_and_old_media(self):
        for tool in ("ditto", "mv"):
            with self.subTest(tool=tool):
                target, agents = self.install_old() if not (self.home / "Applications").exists() else (self.home / "Applications/iMac ReVoyage", self.home / "Library/LaunchAgents")
                old_media = (agents / "re.voyage.media.plist").read_bytes()
                for app in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"):
                    if not (self.package / ("iMac ReVoyage " + app + ".app")).exists(): self.app(app)
                pattern = '*"Media Bridge.app"' if tool == "ditto" else '*"/apps/iMac ReVoyage Media Bridge.app"'
                self.fail_tool(tool, pattern)
                result = self.run_installer()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("设备共享模块", result.stderr)
                self.assertTrue((target / "iMac ReVoyage Rescue.app/Contents/MacOS/fixture").exists())
                self.assertTrue((target / "iMac ReVoyage Media Bridge.app/old").exists())
                self.assertEqual((agents / "re.voyage.media.plist").read_bytes(), old_media)
                (self.fakebin / tool).unlink()

    def test_plists_escape_paths_without_python_runtime(self):
        # Native plist serialization must preserve XML-sensitive characters.
        package = self.package / 'package & "special"'
        package.mkdir()
        shutil.copy(SCRIPT, package / SCRIPT.name)
        for app in ("Receiver", "Rescue", "Storage Watcher"):
            self.app(app)
            shutil.move(str(self.package / ("iMac ReVoyage " + app + ".app")), package)
        self.package = package
        with tempfile.TemporaryDirectory(prefix='revoyage-install-test-&"special"-') as directory:
            home = Path(directory).resolve() / "home"; home.mkdir()
            result = self.run_installer(root=home)
            self.assertEqual(result.returncode, 0, result.stderr)
            info = plistlib.loads((home / "Library/LaunchAgents/re.voyage.rescue.plist").read_bytes())
            self.assertEqual(info["ProgramArguments"][0], str(home / "Applications/iMac ReVoyage/iMac ReVoyage Rescue.app/Contents/MacOS/RescueReceiver"))
        self.assertNotIn("/usr/bin/python", SCRIPT.read_text().lower())

    def test_failed_service_restart_restores_previous_running_services(self):
        target, agents = self.install_old()
        for app in ("Receiver", "Rescue", "Storage Watcher", "Media Bridge"): self.app(app)
        state = self.root / "service-state"; state.mkdir()
        for label in ("rescue", "receiver", "storage", "media"): (state / ("re.voyage." + label)).touch()
        # Instrument only this temporary script copy so the real transaction's
        # service branches run against a fake executable. The shipped fixture
        # mode continues to forbid all actual launchctl calls.
        copied = self.package / SCRIPT.name
        copied.write_text(copied.read_text().replace('"${REVOYAGE_DRY_RUN:-0}" != 1', '"${REVOYAGE_FIXTURE_SERVICES:-0}" == 1'))
        codesign = self.fakebin / "codesign"
        codesign.write_text("#!/bin/sh\nexit 0\n"); codesign.chmod(0o755)
        fake = self.fakebin / "launchctl"
        fake.write_text("#!" + sys.executable + "\n" + r'''import json, os, plistlib, sys
from pathlib import Path
state = Path(os.environ["REVOYAGE_SERVICE_STATE"])
command = sys.argv[1]
if command in ("print", "bootout"):
    label = sys.argv[2].split("/")[-1]
    if command == "print": sys.exit(0 if (state / label).exists() else 1)
    (state / label).unlink(missing_ok=True)
    info = {"command": command, "label": label}
else:
    plist = plistlib.loads(Path(sys.argv[3]).read_bytes())
    label = plist["Label"]
    info = {"command": command, "label": label, "old": plist.get("Old", False)}
    if label == "re.voyage.receiver" and not (state / "failed-once").exists():
        (state / "failed-once").touch()
        sys.exit(1)
    (state / label).touch()
with (state / "events.jsonl").open("a") as output: output.write(json.dumps(info) + "\n")
''')
        fake.chmod(0o755)
        self.environment.update(REVOYAGE_FIXTURE_SERVICES="1", REVOYAGE_SERVICE_STATE=str(state))
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        for label in ("rescue", "receiver", "storage", "media"): self.assertTrue((state / ("re.voyage." + label)).exists())
        self.assertTrue((target / "iMac ReVoyage Rescue.app/old").exists())
        events = [json.loads(line) for line in (state / "events.jsonl").read_text().splitlines()]
        restored = {event["label"] for event in events if event["command"] == "bootstrap" and event.get("old")}
        self.assertEqual(restored, {"re.voyage.rescue", "re.voyage.receiver", "re.voyage.storage"})
        self.assertFalse(any(event["label"] == "re.voyage.media" for event in events))

    def test_airdrop_attributes_are_removed_from_staged_copy(self):
        for app in ("Receiver", "Rescue", "Storage Watcher"): self.app(app)
        source = self.package / "iMac ReVoyage Rescue.app"
        subprocess.run(["xattr", "-w", "com.apple.quarantine", "0081;test;AirDrop;", str(source)], check=True)
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.home / "Applications/iMac ReVoyage/iMac ReVoyage Rescue.app"
        self.assertNotIn("com.apple.quarantine", subprocess.check_output(["xattr", str(installed)], text=True))
        self.assertIn("com.apple.quarantine", subprocess.check_output(["xattr", str(source)], text=True))

    def test_local_signature_repair_and_failure_preserve_transaction(self):
        for success in (True, False):
            with self.subTest(success=success):
                target, _ = self.install_old() if not (self.home / "Applications").exists() else (self.home / "Applications/iMac ReVoyage", None)
                for app in ("Receiver", "Rescue", "Storage Watcher"):
                    if not (self.package / ("iMac ReVoyage " + app + ".app")).exists(): self.app(app)
                copied = self.package / SCRIPT.name
                # Enable only the signature branch against a stub. Services stay disabled.
                copied.write_text(SCRIPT.read_text().replace(
                    'if [[ "${REVOYAGE_DRY_RUN:-0}" != 1 ]]; then\n        if ! codesign',
                    'if true; then\n        if ! codesign'))
                fake = self.fakebin / "codesign"
                fake.write_text('#!/bin/sh\nfor bundle do :; done\ncase "$1" in\n--verify) test -f "$bundle/repaired";;\n--force) ' +
                    ('touch "$bundle/repaired"' if success else 'exit 1') + '\n;;\nesac\n')
                fake.chmod(0o755)
                result = self.run_installer()
                self.assertEqual(result.returncode == 0, success, result.stderr)
                installed = target / "iMac ReVoyage Rescue.app"
                self.assertTrue((installed / "repaired").exists())
                self.assertFalse((self.root / "service-called").exists())

    def test_fixture_mode_rejects_real_home_and_non_dry_run(self):
        self.assertEqual(self.run_installer(root=Path.home()).returncode, 64)
        self.assertEqual(self.run_installer(dry=False).returncode, 64)
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
