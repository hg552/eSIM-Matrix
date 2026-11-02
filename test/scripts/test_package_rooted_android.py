import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/package_rooted_android.py"
spec = importlib.util.spec_from_file_location("package_rooted_android", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RootedModuleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / "app.apk"
        self.output = Path(self.temp.name) / "module.zip"
        with zipfile.ZipFile(self.apk, "w") as apk:
            apk.writestr("AndroidManifest.xml", b"test APK manifest")

    def test_install_path_matches_permissions_and_customizer(self):
        module.package(self.apk, self.output, "2.4.0+600")
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read(module.APP_PATH), self.apk.read_bytes())
            self.assertIn(b'package="ee.nekoko.nlpa2"', archive.read(module.PERMISSION_PATH))
            self.assertIn(b"/system/priv-app/ee.nekoko.nlpa2", archive.read("customize.sh"))
            self.assertIn(b"version=v2.4.0\nversionCode=600", archive.read("module.prop"))
            self.assertEqual(archive.getinfo("customize.sh").external_attr >> 16, 0o100755)

    def test_repeated_packaging_has_no_stale_files(self):
        module.package(self.apk, self.output, "2.4.0+600")
        original = self.output.read_bytes()
        module.package(self.apk, self.output, "2.4.0+600")
        self.assertEqual(self.output.read_bytes(), original)

    def test_bad_version_is_rejected(self):
        with self.assertRaises(ValueError):
            module.package(self.apk, self.output, "master")

    def test_an_arbitrary_zip_is_not_an_apk(self):
        with zipfile.ZipFile(self.apk, "w") as apk:
            apk.writestr("other-file", b"not an APK")
        with self.assertRaises(ValueError):
            module.package(self.apk, self.output, "2.4.0+600")


if __name__ == "__main__":
    unittest.main()
