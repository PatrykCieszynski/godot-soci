#!/usr/bin/env python3
"""Run the installable addon archive in a minimal, clean Godot project."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str]) -> None:
    print("Running:", " ".join(command), flush=True)
    completed = subprocess.run(command, capture_output=True, text=True,
                               timeout=120, check=False, errors="replace")
    print(completed.stdout, flush=True)
    print(completed.stderr, flush=True)
    if completed.returncode != 0:
        raise RuntimeError(f"Command exited with {completed.returncode}: {command}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--zip", required=True, type=Path)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="godot-soci-smoke-") as temp:
        project = Path(temp)
        with zipfile.ZipFile(args.zip) as archive:
            for entry in archive.namelist():
                parts = Path(entry).parts
                if len(parts) < 3 or parts[:2] != ("addons", "godot_soci") or ".." in parts:
                    raise RuntimeError(f"Unexpected path in addon archive: {entry}")
            archive.extractall(project)
        (project / "project.godot").write_text(
            'config_version=5\n[application]\nconfig/name="Godot SOCI Package Smoke"\n'
            '[rendering]\nrenderer/rendering_method="gl_compatibility"\n',
            encoding="utf-8",
        )
        (project / "smoke.gd").write_bytes((ROOT / "tests/release_smoke.gd").read_bytes())
        binary = str(Path(args.godot).resolve())
        run([binary, "--headless", "--path", str(project), "--editor",
             "--quit-after", "120", "--frame-delay", "50"])
        command = [binary, "--headless", "--path", str(project),
                   "--script", "res://smoke.gd"]
        print("Running packaged smoke script:", " ".join(command), flush=True)
        process = subprocess.run(command, capture_output=True, text=True,
                                 timeout=90, check=False, errors="replace")
        output = process.stdout + process.stderr
        print(output, flush=True)
        if process.returncode != 0 or "PACKAGED ADDON SMOKE PASS" not in output:
            raise RuntimeError(f"Addon smoke failed: exit={process.returncode}")


if __name__ == "__main__":
    main()
