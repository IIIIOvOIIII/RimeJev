#!/usr/bin/env python3
"""Compile the unmodified input adapter with in-memory boundary stubs on macOS."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "native/JevIntegration.swift").read_text(encoding="utf-8")
    start, end = "final class JevInputAdapter {", "final class JevPreferences:"
    if source.count(start) != 1 or source.count(end) != 1:
        raise SystemExit("Expected unique JevInputAdapter/JevPreferences extraction boundaries")
    begin, finish = source.index(start), source.index(end)
    if finish <= begin:
        raise SystemExit("JevPreferences must follow JevInputAdapter")
    adapter = source[begin:finish]
    compiler = shutil.which("swiftc")
    if compiler is None:
        raise SystemExit("swiftc with the macOS AppKit SDK is required")

    with tempfile.TemporaryDirectory(prefix="jev-context-adapter-") as tmp:
        work = Path(tmp)
        extracted = work / "AdapterUnderTest.swift"
        extracted.write_text("import Foundation\nimport AppKit\n\n" + adapter, encoding="utf-8")
        sources = [extracted]
        # Snapshot real dependencies as well, since another editor may be working.
        for relative in (
            "JevCore.swift", "JevCommittedContext.swift", "JevLineContext.swift",
            "JevCandidatePlan.swift", "JevBadge.swift",
            "tests/JevContextAdapterStubs.swift", "tests/JevContextAdapterTests.swift",
        ):
            target = work / Path(relative).name
            target.write_bytes((root / "native" / relative).read_bytes())
            sources.append(target)
        executable = work / "JevContextAdapterTests"
        print(f"Testing actual JevInputAdapter (sha256 {hashlib.sha256(adapter.encode()).hexdigest()[:12]})", flush=True)
        subprocess.run(
            [compiler, "-parse-as-library", *map(str, sources),
             "-framework", "AppKit", "-o", str(executable)],
            cwd=work, check=True, timeout=90,
        )
        subprocess.run([str(executable)], cwd=work, check=True, timeout=30)
    print("Context adapter tests PASS; temporary sources and executable removed", flush=True)


if __name__ == "__main__":
    main()
