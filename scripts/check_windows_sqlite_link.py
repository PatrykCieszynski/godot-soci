#!/usr/bin/env python3
"""Verify Windows Godot templates link the optimized vcpkg SQLite library.

Checks the *actual Ninja DLL link command*, not just configuration cache
variables. Godot template_debug/template_release are ABI flavors and both
must use CMake Release with x64-windows-static-md's lib/ (not debug/lib/).
This cannot detect every compiler option inside a prebuilt archive: a separate
SQL runtime test checks sqlite_compileoption_used('SQLITE_DEBUG') == 0.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import re
import subprocess

TRIPLET = "x64-windows-static-md"
RELEASE_LIBRARY = f"vcpkg/installed/{TRIPLET}/lib/sqlite3.lib"
DEBUG_LIBRARY = f"vcpkg/installed/{TRIPLET}/debug/lib/sqlite3.lib"


def verify(cache: str, commands: str, flavor: str) -> None:
    if "CMAKE_BUILD_TYPE:STRING=Release" not in cache:
        raise RuntimeError("Windows template must use CMAKE_BUILD_TYPE=Release")
    if not re.search(rf"(?m)^VCPKG_TARGET_TRIPLET:(?:STRING|UNINITIALIZED)={TRIPLET}$", cache):
        raise RuntimeError(f"Windows must use vcpkg {TRIPLET}")

    dll = f"godot_soci.windows.template_{flavor}.x86_64.dll"
    link_lines = [
        line.replace("\\", "/").lower()
        for line in commands.splitlines()
        if dll in line.lower() and
        ("link.exe" in line.lower() or "lld-link" in line.lower())
    ]
    if len(link_lines) != 1:
        raise RuntimeError(f"Expected exactly one {dll} DLL link command; found {len(link_lines)}")
    link = link_lines[0]
    if DEBUG_LIBRARY in link:
        raise RuntimeError(f"{dll} pulls SQLite from vcpkg debug/lib")
    if RELEASE_LIBRARY not in link:
        raise RuntimeError(f"{dll} does not link the optimized vcpkg lib/sqlite3.lib")
    print(f"WINDOWS SQLITE RELEASE LINK PASS: {dll} => {RELEASE_LIBRARY}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--flavor", choices=["debug", "release"], required=True)
    args = parser.parse_args()
    cache = (args.build_dir / "CMakeCache.txt").read_text(encoding="utf-8")
    proc = subprocess.run(
        ["ninja", "-C", str(args.build_dir), "-t", "commands"],
        capture_output=True, check=True, text=True, errors="replace",
    )
    verify(cache, proc.stdout, args.flavor)


if __name__ == "__main__":
    main()
