import hashlib
import plistlib
import tempfile
import sys
import struct
import unittest
import zipfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT))

from scripts.validate_ipa import PackageValidationError, inspect_ipa


def make_package(path: Path, *, payload: bool = True, info: bool = True, traversal: str | None = None,
                 symlink: bool = False, extras: int = 0, bomb: bool = False) -> bytes:
    plist = plistlib.dumps({
        "CFBundleIdentifier": "org.dreyze.testfixture",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": "16.0",
        "CFBundleExecutable": "Fixture",
        "CFBundleDisplayName": "Fixture App",
    })
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if payload:
            if info:
                archive.writestr("Payload/Fixture.app/Info.plist", plist)
            archive.writestr("Payload/Fixture.app/Fixture", b"safe generated test executable")
        if traversal:
            archive.writestr(traversal, b"unsafe")
        if symlink:
            link = zipfile.ZipInfo("Payload/Fixture.app/linked")
            link.create_system = 3
            link.external_attr = (0o120777 << 16)
            archive.writestr(link, "../../escape")
        for index in range(extras):
            archive.writestr(f"Payload/Fixture.app/extra-{index}", b"x")
        if bomb:
            archive.writestr("Payload/Fixture.app/repetitive.bin", bytes(2 * 1024 * 1024))
    return hashlib.sha256(path.read_bytes()).digest()


class ValidateIpaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="dreyzestore-test-")
        self.path = Path(self.directory.name) / "fixture.ipa"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_valid_generated_fixture_has_expected_metadata_and_checksum(self) -> None:
        digest = make_package(self.path)
        result = inspect_ipa(str(self.path), self.path.stat().st_size)
        self.assertEqual(result["bundleIdentifier"], "org.dreyze.testfixture")
        self.assertEqual(result["version"], "1.0.0")
        self.assertEqual(result["sha256"], digest.hex())

    def test_rejects_malformed_zip(self) -> None:
        self.path.write_bytes(b"not a zip archive")
        with self.assertRaises(PackageValidationError):
            inspect_ipa(str(self.path))

    def test_rejects_package_without_payload_app(self) -> None:
        make_package(self.path, payload=False)
        with self.assertRaisesRegex(PackageValidationError, "Payload"):
            inspect_ipa(str(self.path))

    def test_rejects_missing_info_plist(self) -> None:
        make_package(self.path, info=False)
        with self.assertRaises(PackageValidationError) as error:
            inspect_ipa(str(self.path))
        self.assertEqual(error.exception.code, "missing_info_plist")

    def test_rejects_parent_traversal(self) -> None:
        make_package(self.path, traversal="Payload/../outside.txt")
        with self.assertRaisesRegex(PackageValidationError, "traversal"):
            inspect_ipa(str(self.path))

    def test_rejects_absolute_paths(self) -> None:
        make_package(self.path, traversal="/Payload/escape")
        with self.assertRaisesRegex(PackageValidationError, "absolute"):
            inspect_ipa(str(self.path))

    def test_rejects_symlinks(self) -> None:
        make_package(self.path, symlink=True)
        with self.assertRaisesRegex(PackageValidationError, "Symbolic"):
            inspect_ipa(str(self.path))

    def test_rejects_high_compression_ratio(self) -> None:
        make_package(self.path, bomb=True)
        with self.assertRaisesRegex(PackageValidationError, "compression ratio"):
            inspect_ipa(str(self.path))

    def test_rejects_entry_limit(self) -> None:
        make_package(self.path, extras=20_000)
        with self.assertRaisesRegex(PackageValidationError, "number of entries"):
            inspect_ipa(str(self.path))

    def test_rejects_oversized_central_directory_before_parsing(self) -> None:
        make_package(self.path)
        data = bytearray(self.path.read_bytes())
        eocd = data.rfind(b"PK\x05\x06")
        struct.pack_into("<I", data, eocd + 12, 32 * 1024 * 1024 + 1)
        self.path.write_bytes(data)
        with self.assertRaisesRegex(PackageValidationError, "central directory"):
            inspect_ipa(str(self.path))

    def test_rejects_expected_size_mismatch(self) -> None:
        make_package(self.path)
        with self.assertRaisesRegex(PackageValidationError, "byte count"):
            inspect_ipa(str(self.path), self.path.stat().st_size + 1)

    def test_rejects_package_over_maximum_without_reading_it(self) -> None:
        # Sparse-file fixture: this exercises the cap without writing a large package into the repository.
        with self.path.open("wb") as package:
            package.truncate(1_073_741_825)
        with self.assertRaises(PackageValidationError) as error:
            inspect_ipa(str(self.path))
        self.assertEqual(error.exception.code, "package_size_invalid")


if __name__ == "__main__":
    unittest.main()
