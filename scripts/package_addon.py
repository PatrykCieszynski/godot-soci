#!/usr/bin/env python3
"""Build a deterministic, installable godot-soci addon archive.

Usage:
  python scripts/package_addon.py platform --platform linux --out dist/godot-soci-linux.zip --vcpkg-share vcpkg/installed/x64-linux/share --upstream build-debug/_deps
  python scripts/package_addon.py combine --linux dist/godot-soci-linux.zip --windows dist/godot-soci-windows.zip --out dist/godot-soci-v0.3.1.zip
"""
from __future__ import annotations

import argparse
import configparser
import hashlib
from pathlib import Path, PurePosixPath
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addons" / "godot_soci"
PREFIX = PurePosixPath("addons/godot_soci")
PLATFORMS = ("linux", "windows")
SUFFIXES = {"linux": ".so", "windows": ".dll"}
EXACT_NAMES = {
    platform: tuple(
        f"bin/{platform}/godot_soci.{platform}.template_{flavor}.x86_64{SUFFIXES[platform]}"
        for flavor in ("debug", "release")
    )
    for platform in PLATFORMS
}


def manifest_paths() -> set[str]:
    parser = configparser.ConfigParser(interpolation=None)
    if not parser.read(ADDON / "soci.gdextension", encoding="utf-8"):
        raise RuntimeError("Missing soci.gdextension")
    if parser["configuration"].get("compatibility_minimum") != '"4.7"':
        raise RuntimeError("Expected Godot minimum 4.7")
    return {value.strip('"').removeprefix("./") for value in parser["libraries"].values()}


def write_zip(output: Path, entries: dict[str, bytes]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)
    print(f"Wrote {output} ({output.stat().st_size:,} bytes)")


def addon_path(relative: str) -> str:
    return (PREFIX / relative).as_posix()


def build_platform(args: argparse.Namespace) -> None:
    expected = EXACT_NAMES[args.platform]
    defined = manifest_paths()
    for binary in expected:
        if binary not in defined:
            raise RuntimeError(f"Binary missing from manifest: {binary}")
        if not (ADDON / binary).is_file():
            raise RuntimeError(f"Compiled {args.platform} binary absent: {binary}")

    entries: dict[str, bytes] = {}
    for name in ("soci.gdextension", "database.gd", "async_database.gd", "README.md"):
        entries[addon_path(name)] = (ADDON / name).read_bytes()
    entries[addon_path("LICENSE")] = (ROOT / "LICENSE").read_bytes()

    for binary in expected:
        entries[addon_path(binary)] = (ADDON / binary).read_bytes()

    upstream = Path(args.upstream)
    for name, path in (
        ("SOCI-LICENSE.txt", upstream / "soci_src-src" / "LICENSE_1_0.txt"),
        ("GODOT-CPP-LICENSE.txt", upstream / "godot_cpp-src" / "LICENSE.md"),
    ):
        if not path.is_file():
            raise RuntimeError(f"Missing upstream license: {path}")
        entries[addon_path("licenses/" + name)] = path.read_bytes()

    share = Path(args.vcpkg_share)
    if not share.is_dir():
        raise RuntimeError(f"Missing vcpkg license folder: {share}")
    found = set()
    for copyright_file in sorted(share.glob("*/copyright")):
        package = copyright_file.parent.name
        found.add(package)
        entries[addon_path(f"licenses/vcpkg/{package}.txt")] = copyright_file.read_bytes()
    if not {"libpq", "sqlite3", "openssl"}.issubset(found):
        raise RuntimeError(f"Missing core vcpkg licenses; found: {sorted(found)}")

    entries[addon_path("THIRD_PARTY_NOTICES.md")] = (
        "# Third-party notices\n\n"
        "This binary distribution statically links SOCI, godot-cpp, PostgreSQL libpq, "
        "SQLite and their native dependencies. License texts for SOCI, godot-cpp and "
        "vcpkg-resolved third-party packages are shipped under `licenses/`. "
        "The godot-soci wrapper itself is MIT-licensed (`LICENSE`).\n"
        "See also https://github.com/SOCI/soci and https://github.com/godotengine/godot-cpp.\n"
    ).encode("utf-8")
    write_zip(Path(args.out), entries)


def combine(args: argparse.Namespace) -> None:
    entries: dict[str, bytes] = {}
    for platform in PLATFORMS:
        archive_path = Path(getattr(args, platform))
        with zipfile.ZipFile(archive_path) as archive:
            for name in archive.namelist():
                data = archive.read(name)
                if name in entries and entries[name] != data:
                    if name.startswith(addon_path("licenses/vcpkg/")):
                        # Package notices can differ between OS triplets; preserve both.
                        alternate = name.removesuffix(".txt") + f"-{platform}.txt"
                        entries[alternate] = data
                        continue
                    raise RuntimeError(f"Conflicting addon file across platforms: {name}")
                entries[name] = data

    expected = {addon_path(filename) for names in EXACT_NAMES.values() for filename in names}
    missing = expected.difference(entries)
    if missing:
        raise RuntimeError(f"Combined archive missing libraries: {sorted(missing)}")
    for path in expected:
        if not entries[path]:
            raise RuntimeError(f"Empty library in combined archive: {path}")
    write_zip(Path(args.out), entries)


if __name__ == "__main__":
    cli = argparse.ArgumentParser()
    commands = cli.add_subparsers(dest="command", required=True)
    p = commands.add_parser("platform")
    p.add_argument("--platform", choices=PLATFORMS, required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--vcpkg-share", required=True)
    p.add_argument("--upstream", default="build-debug/_deps")
    p.set_defaults(func=build_platform)
    p = commands.add_parser("combine")
    p.add_argument("--linux", required=True)
    p.add_argument("--windows", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=combine)
    cli.add_argument("--version", action="version", version="package_addon v1")
    args = cli.parse_args()
    args.func(args)
