"""Verify signed fixtures only; never invoke administrator install or load HAL."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

APP = Path(sys.argv.pop(1)).resolve()
shutil._HAS_FCOPYFILE = False

class SpeakerInstallerTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='revoyage-speaker-installer-')
        self.root = Path(self.work.name).resolve()
        self.app = self.root / 'Sender.app'
        shutil.copytree(APP, self.app, symlinks=True)
        for bundle in self.app.rglob('*.xctest'):
            shutil.rmtree(bundle)
        subprocess.run(['codesign', '--force', '--sign', '-', str(self.app / 'Contents/Resources/ReVoyageSpeaker.driver')], check=True, capture_output=True)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(self.app)], check=True, capture_output=True)

    def tearDown(self):
        self.work.cleanup()

    def check(self, app=None):
        helper = self.app / 'Contents/MacOS/ReVoyageSpeakerInstaller'
        return subprocess.run([str(helper), '--app', str(app or self.app), '--check'], capture_output=True, timeout=15)

    def test_valid_packaged_speaker_and_sender_are_accepted_without_installing(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tampered_driver_is_rejected(self):
        path = self.app / 'Contents/Resources/ReVoyageSpeaker.driver/Contents/Info.plist'
        path.write_bytes(path.read_bytes() + b'\n')
        self.assertEqual(self.check().returncode, 78)

    def test_foreign_driver_id_is_rejected_even_after_resigning(self):
        plugin = self.app / 'Contents/Resources/ReVoyageSpeaker.driver'
        path = plugin / 'Contents/Info.plist'
        data = plistlib.loads(path.read_bytes())
        data['CFBundleIdentifier'] = 'example.foreign'
        path.write_bytes(plistlib.dumps(data))
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(self.app)], check=True, capture_output=True)
        self.assertEqual(self.check().returncode, 78)

    def test_app_symlink_is_rejected(self):
        link = self.root / 'linked.app'
        link.symlink_to(self.app)
        self.assertEqual(self.check(link).returncode, 78)

if __name__ == '__main__':
    unittest.main()
