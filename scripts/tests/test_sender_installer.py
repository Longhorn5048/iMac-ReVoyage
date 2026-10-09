#!/usr/bin/env python3
"""Exercise installation with a real signed bundle; never launch the app."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
shutil._HAS_FCOPYFILE = False


class SenderInstallerTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='revoyage-sender-installer-')
        self.base = Path(self.work.name)
        self.applications = self.base / 'Applications'
        self.applications.mkdir()
        self.source = self.base / 'new.app'
        shutil.copytree(ROOT / 'build/TargetBridge.app', self.source, symlinks=True)
        self.destination = self.applications / 'iMac ReVoyage Sender.app'
        self.destination.mkdir()
        (self.destination / 'old-version').write_text('keep for rollback')
        self.stubs = self.base / 'bin'
        self.stubs.mkdir()
        self.launch = self.base / 'launch.txt'
        for name, body in {
            'pgrep': '#!/bin/sh\nexit 1\n',
            'open': '#!/bin/sh\nprintf "%s\\n" "$@" > "$REVOYAGE_TEST_LAUNCH"\n',
            'mv': '#!/bin/sh\ncase "$1" in *.ReVoyage-Sender-install-*.app) if [ "$REVOYAGE_TEST_FAIL_RENAME" = 1 ]; then exit 1; fi;; esac\nexec /bin/mv "$@"\n',
        }.items():
            path = self.stubs / name
            path.write_text(body)
            path.chmod(0o755)

    def tearDown(self):
        self.work.cleanup()

    def install(self, fail_rename=False):
        environment = dict(os.environ,
            PATH=str(self.stubs) + ':/usr/bin:/bin:/usr/sbin:/sbin',
            REVOYAGE_SENDER_APPLICATIONS_DIR=str(self.applications),
            REVOYAGE_TEST_LAUNCH=str(self.launch),
            REVOYAGE_TEST_FAIL_RENAME='1' if fail_rename else '0')
        return subprocess.run(['/bin/zsh', str(ROOT / 'scripts/install_sender.command'), str(self.source)],
            env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def testVerifiedBundleReplacesOldAppAndLaunchesOnlyTheInstalledPath(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout)
        info = plistlib.loads((self.destination / 'Contents/Info.plist').read_bytes())
        source_info = plistlib.loads((self.source / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], source_info['CFBundleShortVersionString'])
        self.assertEqual(self.launch.read_text().splitlines(), ['-n', str(self.destination)])
        self.assertTrue((self.applications / '.ReVoyage-Sender-previous.app.backup/old-version').exists())

    def testInvalidSignatureLeavesOldAppInPlaceAndDoesNotLaunch(self):
        info = self.source / 'Contents/Info.plist'
        info.write_bytes(info.read_bytes() + b'\n')
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / 'old-version').exists())
        self.assertFalse(self.launch.exists())

    def testFailedReplacementRestoresOldAppWithoutLaunching(self):
        result = self.install(fail_rename=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / 'old-version').exists())
        self.assertFalse(self.launch.exists())
        self.assertFalse(list(self.applications.glob('.ReVoyage-Sender-install-*.app')))


if __name__ == '__main__':
    unittest.main()
