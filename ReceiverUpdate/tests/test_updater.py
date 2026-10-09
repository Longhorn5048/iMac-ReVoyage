"""Uploads only to a fixture executable on loopback; installer services are disabled."""
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import zipfile

HELPER = Path(sys.argv.pop(1)).resolve()


class UpdaterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packages = tempfile.TemporaryDirectory(prefix="revoyage-updater-packages-")
        cls.root = Path(cls.packages.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        executable = cls.root / "tiny-intel"
        subprocess.run(["clang", "-arch", "x86_64", "-mmacosx-version-min=10.15", str(source), "-o", str(executable)], check=True)
        cls.valid = cls.make_package(executable)

    @classmethod
    def tearDownClass(cls):
        cls.packages.cleanup()

    @classmethod
    def make_package(cls, executable, wrong_identifier=False, missing_updater=False):
        package = cls.root / str(uuid.uuid4()) / "Receiver"
        package.mkdir(parents=True)
        roles = {"Receiver":("re.voyage.receiver", "TargetBridgeReceiver"),
                 "Rescue":("re.voyage.rescue", "RescueReceiver"),
                 "Storage Watcher":("re.voyage.storage-watcher", "StorageWatcher"),
                 "Media Bridge":("re.voyage.media-bridge", "ReVoyageMediaBridge")}
        for name, (identifier, main) in roles.items():
            app = package / ("iMac ReVoyage " + name + ".app")
            macos = app / "Contents/MacOS"
            macos.mkdir(parents=True)
            shutil.copy(executable, macos / main)
            if name == "Receiver" and not missing_updater:
                shutil.copy(executable, macos / "ReVoyageReceiverUpdater")
                subprocess.run(["codesign", "--force", "--sign", "-", str(macos / "ReVoyageReceiverUpdater")], check=True, capture_output=True)
            info = {"CFBundleIdentifier": "foreign.bundle" if wrong_identifier and name == "Receiver" else identifier,
                    "CFBundleExecutable":main, "CFBundlePackageType":"APPL", "CFBundleVersion":"fixture-new",
                    "LSMinimumSystemVersion":"10.15"}
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True, capture_output=True)
        # Must never execute the package's top-level installer.
        (package / "install_receiver.command").write_text('#!/bin/sh\ntouch "$REVOYAGE_FORBIDDEN_INSTALLER_MARKER"\nexit 88\n')
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
            for file in package.rglob("*"):
                archive.write(file, file.relative_to(package.parent).as_posix())
            archive.writestr("Sources/ignore.txt", "Do not extract source or Sender files.")
        return buffer.getvalue()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="revoyage-install-test-")
        self.base = Path(self.temporary.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        self.apps = self.home / "Applications/iMac ReVoyage"
        for name in ["Receiver", "Rescue", "Storage Watcher", "Media Bridge"]:
            bundle = self.apps / ("iMac ReVoyage " + name + ".app")
            bundle.mkdir(parents=True)
            (bundle / "old").write_text(name)
        self.fakebin = self.base / "bin"
        self.fakebin.mkdir()
        fake = self.fakebin / "launchctl"
        fake.write_text('#!/bin/sh\ntouch "$REVOYAGE_TEST_SERVICE_MARKER"\nexit 99\n')
        fake.chmod(0o755)
        self.environment = {**os.environ, "PATH":str(self.fakebin)+":"+os.environ["PATH"],
                            "REVOYAGE_TEST_SERVICE_MARKER":str(self.base / "service-called"),
                            "REVOYAGE_FORBIDDEN_INSTALLER_MARKER":str(self.base / "uploaded-installer-called"),
                            "ASAN_OPTIONS":"detect_leaks=0"}
        self.start()

    def start(self):
        self.stderr = (self.base / "stderr.log").open("ab")
        self.process = subprocess.Popen([str(HELPER), "--test-root", str(self.home), "--port", "0"],
                                        stdout=subprocess.PIPE, stderr=self.stderr, env=self.environment, text=True)
        line = self.process.stdout.readline()
        self.assertTrue(line.startswith("Updater listening "), line + (self.base / "stderr.log").read_text())
        self.port = int(line.split()[-1])

    def stop(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.process.stdout.close()
        self.stderr.close()

    def tearDown(self):
        self.stop()
        self.assertFalse((self.base / "service-called").exists())
        self.assertFalse((self.base / "uploaded-installer-called").exists())
        errors = (self.base / "stderr.log").read_text()
        self.assertNotIn("ERROR: AddressSanitizer", errors)
        self.assertNotIn("runtime error:", errors)
        self.temporary.cleanup()

    def status(self):
        client = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        client.request("GET", "/status")
        response = client.getresponse()
        self.assertEqual(response.status, 200)
        value = json.loads(response.read())
        client.close()
        return value

    def upload(self, body, sha=None):
        request = str(uuid.uuid4())
        client = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        client.request("POST", "/update", body, {"X-ReVoyage-SHA256":sha or hashlib.sha256(body).hexdigest(),
                                                "X-ReVoyage-Request-ID":request})
        response = client.getresponse()
        code, value = response.status, json.loads(response.read())
        client.close()
        return code, value, request

    def wait_result(self, request):
        deadline = time.monotonic()+15
        while time.monotonic()<deadline:
            value = self.status()
            if value.get("requestID")==request and value["phase"] in ("completed", "failed"):
                return value
            time.sleep(.05)
        self.fail("No result: " + json.dumps(self.status()))

    def assert_old_install(self):
        for name in ["Receiver", "Rescue", "Storage Watcher", "Media Bridge"]:
            self.assertEqual((self.apps / ("iMac ReVoyage " + name + ".app/old")).read_text(), name)

    def test_success_installs_all_apps_and_updater_without_services_or_uploaded_script(self):
        self.assertEqual(self.status()["phase"], "idle")
        code, _, request = self.upload(self.valid)
        self.assertEqual(code, 202)
        value = self.wait_result(request)
        log = self.home / "Library/Logs/iMac ReVoyage/updater-install.log"
        self.assertEqual(value["phase"], "completed", str(value) + "\n" + (log.read_text() if log.exists() else ""))
        self.assertEqual(value["receiverBuild"], "fixture-new")
        updater = self.home / "Library/LaunchAgents/re.voyage.updater.plist"
        info = plistlib.loads(updater.read_bytes())
        self.assertEqual(info["Label"], "re.voyage.updater")
        self.assertEqual(len(info["ProgramArguments"]), 1)
        self.assertTrue(info["KeepAlive"] and info["RunAtLoad"])
        self.assertTrue(Path(info["ProgramArguments"][0]).is_relative_to(self.home))
        self.assertFalse((self.base / "Sources").exists())
        self.assertFalse(list((self.home / "Library/Application Support/TargetBridge Receiver/Updates").glob("*/")))
        self.stop(); self.start()
        self.assertEqual(self.status()["requestID"], request)
        self.assertEqual(self.status()["phase"], "completed")

    def test_checksum_mismatch_cannot_touch_installation(self):
        code, value, request = self.upload(self.valid, "0"*64)
        self.assertEqual(code, 400)
        self.assertEqual(value["error"], "transfer_failed")
        self.assertEqual(self.wait_result(request)["phase"], "failed")
        self.assert_old_install()

    def test_single_intel_fat_wrapper_is_catalina_compatible(self):
        fat = self.root / "tiny-fat-intel"
        subprocess.run(["lipo", "-create", str(self.root / "tiny-intel"), "-output", str(fat)], check=True)
        code, _, request = self.upload(self.make_package(fat))
        self.assertEqual(code, 202)
        self.assertEqual(self.wait_result(request)["phase"], "completed")

    @unittest.skipUnless(os.environ.get("REVOYAGE_UPDATE_PACKAGE"), "No distribution ZIP supplied")
    def test_built_distribution_installs_with_catalina_validation(self):
        body = Path(os.environ["REVOYAGE_UPDATE_PACKAGE"]).read_bytes()
        code, _, request = self.upload(body)
        self.assertEqual(code, 202)
        value = self.wait_result(request)
        log = self.home / "Library/Logs/iMac ReVoyage/updater-install.log"
        self.assertEqual(value["phase"], "completed", str(value)+"\n"+(log.read_text() if log.exists() else "")+"\n"+(self.base / "stderr.log").read_text())
        self.assertTrue((self.apps / "iMac ReVoyage Receiver.app/Contents/MacOS/ReVoyageReceiverUpdater").exists())
        self.assertEqual(len(list((self.home / "Library/LaunchAgents").glob("*.plist"))), 5)

    def test_invalid_archives_cannot_touch_installation(self):
        for kind in ["garbage", "traversal", "symlink", "duplicate", "local-name"]:
            with self.subTest(kind=kind):
                if kind=="garbage": body = b"invalid zip"
                else:
                    buffer = io.BytesIO()
                    with zipfile.ZipFile(buffer,"w") as archive:
                        if kind=="traversal": archive.writestr("Receiver/../escape", "bad")
                        elif kind=="symlink":
                            entry=zipfile.ZipInfo("Receiver/link"); entry.create_system=3; entry.external_attr=0o120777<<16
                            archive.writestr(entry,"../../escape")
                        elif kind=="duplicate":
                            archive.writestr("Receiver/duplicate", "one")
                            archive.writestr("Receiver/duplicate", "two")
                        else: archive.writestr("Receiver/file", "data")
                    body=buffer.getvalue()
                    if kind=="local-name": body=body.replace(b"Receiver/file",b"Receiver/evil",1)
                code, _, request=self.upload(body)
                self.assertEqual(code,202)
                self.assertEqual(self.wait_result(request)["error"],"invalid_archive")
                self.assert_old_install()

    def test_incompatible_bundle_and_missing_updater_are_rejected(self):
        executable=self.root/"tiny-intel"
        for kwargs in [{"wrong_identifier":True},{"missing_updater":True}]:
            with self.subTest(kwargs=kwargs):
                code, _, request=self.upload(self.make_package(executable,**kwargs))
                self.assertEqual(code,202)
                self.assertEqual(self.wait_result(request)["error"],"incompatible_package")
                self.assert_old_install()
        modern=self.root/"tiny-modern"
        subprocess.run(["clang","-arch","x86_64","-mmacosx-version-min=14.0",str(self.root/"main.c"),"-o",str(modern)],check=True)
        code, _, request=self.upload(self.make_package(modern))
        self.assertEqual(code,202)
        self.assertEqual(self.wait_result(request)["error"],"incompatible_package")
        self.assert_old_install()

    def test_partial_upload_busy_and_restart_mark_interrupted(self):
        request=str(uuid.uuid4())
        sock=socket.create_connection(("127.0.0.1",self.port), timeout=5)
        header=f"POST /update HTTP/1.1\r\nContent-Length: {len(self.valid)}\r\nX-ReVoyage-SHA256: {hashlib.sha256(self.valid).hexdigest()}\r\nX-ReVoyage-Request-ID: {request}\r\n\r\n"
        sock.sendall(header.encode()+self.valid[:100])
        deadline=time.monotonic()+5
        while self.status()["phase"]!="receiving" and time.monotonic()<deadline: time.sleep(.01)
        receipt = self.home / "Library/Application Support/TargetBridge Receiver/Updates/last-update.json"
        deadline = time.monotonic()+5
        while (not receipt.exists() or json.loads(receipt.read_text()).get("requestID") != request) and time.monotonic()<deadline: time.sleep(.01)
        self.assertEqual(json.loads(receipt.read_text())["requestID"], request)
        self.assertEqual(self.upload(self.valid)[0],409)
        sock.shutdown(socket.SHUT_WR)
        self.assertTrue(sock.recv(1024).startswith(b"HTTP/1.1 400"))
        sock.close()
        self.assertEqual(self.wait_result(request)["error"],"transfer_failed")
        self.assert_old_install()
        self.stop()
        receipt=self.home/"Library/Application Support/TargetBridge Receiver/Updates/last-update.json"
        receipt.write_text(json.dumps({"requestID":request,"phase":"installing","error":"","progress":1}))
        orphan = receipt.parent / str(uuid.uuid4())
        orphan.mkdir(); (orphan / "update.zip").write_bytes(b"interrupted upload")
        self.start()
        self.assertEqual(self.status()["error"],"interrupted")
        self.assertFalse(orphan.exists())

    def test_oversized_and_ambiguous_http_rejected_before_transfer(self):
        for length in [str(96*1024*1024+1),"-1","1\r\nContent-Length: 1"]:
            sock=socket.create_connection(("127.0.0.1",self.port),timeout=5)
            header=f"POST /update HTTP/1.1\r\nContent-Length: {length}\r\nX-ReVoyage-SHA256: {'0'*64}\r\nX-ReVoyage-Request-ID: {uuid.uuid4()}\r\n\r\n"
            sock.sendall(header.encode())
            self.assertTrue(sock.recv(1024).startswith(b"HTTP/1.1 400"))
            sock.close()
        self.assertEqual(self.status()["phase"],"idle")
        self.assert_old_install()


if __name__=="__main__":
    unittest.main()
