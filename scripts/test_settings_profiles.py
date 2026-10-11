#!/usr/bin/env python3
"""Test the real Settings implementation with disposable settings under work/."""
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "native/JevIntegration.swift").read_text()
    boundary = "final class JevSocketCall"
    if source.count(boundary) != 1:
        raise SystemExit("Expected one JevSocketCall boundary for Settings extraction")
    source = source.split(boundary, 1)[0]
    support = (
        'FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent('
        '"Library/Application Support/Rime-Jev")'
    )
    if source.count(support) != 1:
        raise SystemExit("Expected one Settings support directory; refusing an unisolated run")

    (root / "work").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="settings-profiles-", dir=root / "work") as tmp:
        fixture = Path(tmp)
        settings = fixture / "support"
        extracted = fixture / "SettingsUnderTest.swift"
        # Relocate storage only; compile every Settings method exactly as written.
        extracted.write_text(source.replace(support, f"URL(fileURLWithPath: {json.dumps(str(settings))})"))
        executable = fixture / "JevSettingsProfileTests"
        subprocess.run(
            [
                "swiftc", "-parse-as-library",
                str(root / "native/JevCore.swift"), str(extracted),
                str(root / "native/tests/JevSettingsProfileTests.swift"),
                "-framework", "AppKit", "-framework", "InputMethodKit",
                "-framework", "Carbon", "-o", str(executable),
            ],
            check=True, timeout=60,
        )
        # A new process makes each check exercise the real lazy Settings loader.
        for scenario in ("missing", "legacy", "corrupt", "wrong-type", "suite", "reload"):
            subprocess.run([str(executable), str(settings), scenario], check=True, timeout=15)
    print("Settings profile tests PASS; temporary fixtures removed", flush=True)


if __name__ == "__main__":
    main()
