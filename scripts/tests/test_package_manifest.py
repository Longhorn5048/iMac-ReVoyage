import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('manifest', Path(__file__).parents[1] / 'package_manifest.py')
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)

class PackageTests(unittest.TestCase):
    def check(self, arch='x86_64', minimum='10.15', library='/usr/lib/libSystem.B.dylib', rpath='@executable_path/../Frameworks', bundled=None):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / 'Receiver.app'
            path = app / 'Contents/MacOS/Receiver'
            path.parent.mkdir(parents=True)
            path.write_bytes(b'fake')
            if bundled:
                library_file = app / 'Contents/Frameworks' / bundled
                library_file.parent.mkdir(parents=True)
                library_file.write_bytes(b'library')
            output = [arch, f'cmd LC_BUILD_VERSION\n minos {minimum}\ncmd LC_RPATH\ncmdsize 48\npath {rpath} (offset 12)', f'{path}:\n\t{library} (compatibility version 1.0.0, current version 1.0.0)\n']
            with patch.object(manifest.subprocess, 'check_output', side_effect=output):
                return manifest.validate_image(path, app, 'x86_64', '10.15')

    def test_catalina_and_older_dependencies_allowed(self):
        self.assertEqual(self.check(minimum='10.13')['minimumOS'], '10.13')
        self.check(minimum='10.15.0')

    def test_modern_dependency_rejected(self):
        with self.assertRaises(ValueError): self.check(minimum='11.0')

    def test_wrong_architecture_rejected(self):
        with self.assertRaises(ValueError): self.check(arch='arm64')

    def test_homebrew_dependency_rejected(self):
        with self.assertRaises(ValueError): self.check(library='/opt/homebrew/lib/libSDL2.dylib')

    def test_missing_bundled_library_rejected(self):
        with self.assertRaises(ValueError): self.check(library='@rpath/libmissing.dylib')

    def test_bundled_library_must_be_on_actual_search_path(self):
        with self.assertRaises(ValueError):
            self.check(library='@rpath/libexample.dylib', rpath='@executable_path', bundled='libexample.dylib')

    def test_bundled_library_on_framework_search_path_allowed(self):
        self.check(library='@rpath/libexample.dylib', bundled='libexample.dylib')

    def test_homebrew_search_path_rejected(self):
        with self.assertRaises(ValueError): self.check(rpath='/opt/homebrew/lib')

if __name__ == '__main__': unittest.main()
