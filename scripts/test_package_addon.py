"""Fast regression checks for cross-platform addon package merging."""
from __future__ import annotations

import argparse
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import zipfile

from package_addon import EXACT_NAMES, PREFIX, combine, normalize_entry


def packaged(relative: str) -> str:
    return f"{PREFIX}/{relative}"


def platform_archive(path: Path, platform: str, line_ending: bytes = b"\n",
                     license_suffix: bytes = b"same", readme: bytes | None = None) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for binary in EXACT_NAMES[platform]:
            archive.writestr(packaged(binary), f"{platform}:{binary}".encode())
        archive.writestr(packaged("LICENSE"), b"First line" + line_ending + b"Second line" + line_ending)
        archive.writestr(packaged("README.md"), readme if readme is not None else
                         b"Readme" + line_ending + b"Same content" + line_ending)
        archive.writestr(packaged("docs/API.md"), b"API" + line_ending)
        archive.writestr(packaged("licenses/vcpkg/libpq.txt"), b"Copyright " + license_suffix + line_ending)


class PackageAddonTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.linux = self.root / "linux.zip"
        self.windows = self.root / "windows.zip"
        self.combined = self.root / "combined.zip"

    def merge(self) -> None:
        combine(argparse.Namespace(linux=str(self.linux),
                                   windows=str(self.windows),
                                   out=str(self.combined)))

    def test_windows_crlf_and_linux_lf_are_equivalent(self) -> None:
        platform_archive(self.linux, "linux", b"\n")
        platform_archive(self.windows, "windows", b"\r\n")
        self.merge()
        with zipfile.ZipFile(self.combined) as archive:
            self.assertEqual(archive.read(packaged("LICENSE")), b"First line\nSecond line\n")
            self.assertEqual(archive.read(packaged("README.md")), b"Readme\nSame content\n")
            self.assertEqual(archive.read(packaged("docs/API.md")), b"API\n")
            for names in EXACT_NAMES.values():
                for binary in names:
                    self.assertTrue(archive.read(packaged(binary)))
        original = self.combined.read_bytes()
        self.merge()
        self.assertEqual(self.combined.read_bytes(), original, "Combined ZIP must be deterministic")

    def test_real_conflict_in_shared_readme_still_fails(self) -> None:
        platform_archive(self.linux, "linux")
        platform_archive(self.windows, "windows", readme=b"Different content\n")
        with self.assertRaisesRegex(RuntimeError, "Conflicting addon file.*README.md"):
            self.merge()

    def test_real_vcpkg_license_differences_are_preserved(self) -> None:
        platform_archive(self.linux, "linux", license_suffix=b"linux-specific")
        platform_archive(self.windows, "windows", license_suffix=b"windows-specific")
        self.merge()
        with zipfile.ZipFile(self.combined) as archive:
            self.assertEqual(archive.read(packaged("licenses/vcpkg/libpq.txt")),
                             b"Copyright linux-specific\n")
            self.assertEqual(archive.read(packaged("licenses/vcpkg/libpq-windows.txt")),
                             b"Copyright windows-specific\n")

    def test_missing_platform_binary_is_rejected(self) -> None:
        platform_archive(self.linux, "linux")
        with zipfile.ZipFile(self.windows, "w") as archive:
            archive.writestr(packaged("LICENSE"), b"First line\nSecond line\n")
        with self.assertRaisesRegex(RuntimeError, "missing libraries"):
            self.merge()

    def test_binary_bytes_are_not_normalized(self) -> None:
        binary_name = packaged(EXACT_NAMES["windows"][0])
        self.assertEqual(normalize_entry(binary_name, b"binary\r\ndata"), b"binary\r\ndata")


if __name__ == "__main__":
    unittest.main()
