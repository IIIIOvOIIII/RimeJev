#!/usr/bin/env python3
"""Explicitly install the pinned private Ollama runtime and selected Tev models."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from rime_jev import tev_runtime as runtime
from rime_jev.tev_models import TEV_MODELS


RUNTIME_URL = "https://github.com/ollama/ollama/releases/download/v0.40.3/ollama-darwin.tgz"
RUNTIME_SHA256 = "a2d1d906a2c8febd9cb18f5c183854d0a6db5dc522940d68b0c0ed048e8dfdea"
RUNTIME_ARCHIVE = runtime.RUNTIME_ROOT / "downloads/ollama-0.40.3-darwin.tgz"
INSTALL_RECEIPT = runtime.RUNTIME_ROOT / "ollama-0.40.3-install.json"
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024
MAX_API_BYTES = 1024 * 1024
MAX_PROGRESS_LINE_BYTES = 16 * 1024
DOWNLOAD_TIMEOUT = 600.0
PULL_TIMEOUT = 3600.0


class Progress:
    """At most 200 progress lines plus four terminal lines; no upstream text."""

    def __init__(self):
        self.count = 0
        self.last = -float("inf")
        self.terminal_count = 0

    def emit(self, stage: str, *, terminal: bool = False, **fields):
        now = time.monotonic()
        if terminal:
            if self.terminal_count >= 4:
                return
            self.terminal_count += 1
        else:
            if self.count >= 200 or now - self.last < 1.0:
                return
            self.count += 1
            self.last = now
        print(json.dumps({"stage": stage, **fields}, separators=(",", ":")), flush=True)


def _official_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    try:
        valid = (parsed.scheme == "https" and parsed.port in {None, 443}
                 and parsed.username is None and parsed.password is None
                 and not parsed.fragment
                 and (url == RUNTIME_URL or parsed.hostname in {
                     "release-assets.githubusercontent.com", "objects.githubusercontent.com",
                 }))
    except ValueError:
        valid = False
    if not valid:
        raise runtime.TevRuntimeError("untrusted_runtime_url")
    return url


class _OfficialRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        _official_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def _download_archive(progress: Progress) -> None:
    RUNTIME_ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    partial = RUNTIME_ARCHIVE.with_suffix(".part")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _OfficialRedirect())
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT
    try:
        with opener.open(_official_url(RUNTIME_URL), timeout=30) as response:
            _official_url(response.geturl())
            with partial.open("wb") as target:
                downloaded = 0
                while chunk := response.read(1024 * 1024):
                    downloaded += len(chunk)
                    if downloaded > MAX_ARCHIVE_BYTES or time.monotonic() >= deadline:
                        raise runtime.TevRuntimeError("runtime_download_limit")
                    target.write(chunk)
                    progress.emit("runtime_download", bytes=downloaded)
        if _sha256(partial) != RUNTIME_SHA256:
            raise runtime.TevRuntimeError("runtime_hash_mismatch")
        partial.replace(RUNTIME_ARCHIVE)
    finally:
        partial.unlink(missing_ok=True)


def _archive_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = []
    names = set()
    total = 0
    for member in archive:
        name = PurePosixPath(member.name)
        if name.is_absolute() or ".." in name.parts or not name.parts or "\\" in member.name:
            raise runtime.TevRuntimeError("unsafe_runtime_archive")
        if name in names or not (member.isfile() or member.isdir() or member.issym()):
            raise runtime.TevRuntimeError("unsafe_runtime_archive")
        if member.issym():
            link = PurePosixPath(member.linkname)
            if link.is_absolute() or ".." in link.parts or not link.parts or "\\" in member.linkname:
                raise runtime.TevRuntimeError("unsafe_runtime_archive")
        names.add(name)
        members.append(member)
        total += member.size
        if len(members) > 4096 or total > MAX_EXTRACTED_BYTES:
            raise runtime.TevRuntimeError("runtime_archive_limit")
    binaries = [member for member in members if member.name == "ollama" and member.isfile()]
    if len(binaries) != 1 or not binaries[0].mode & 0o111:
        raise runtime.TevRuntimeError("runtime_binary_missing")
    return members


def _verify_files(archive: tarfile.TarFile, members: list[tarfile.TarInfo], destination: Path):
    if destination.resolve() != destination:
        raise runtime.TevRuntimeError("unsafe_runtime_destination")
    for member in members:
        target = destination / member.name
        if not target.resolve().is_relative_to(destination):
            raise runtime.TevRuntimeError("unsafe_runtime_destination")
        if member.issym():
            matches = target.is_symlink() and os.readlink(target) == member.linkname
        elif member.isdir():
            matches = target.is_dir() and not target.is_symlink()
        else:
            matches = (target.is_file() and not target.is_symlink()
                       and target.stat().st_size == member.size
                       and (not member.mode & 0o111 or os.access(target, os.X_OK)))
            if matches:
                with archive.extractfile(member) as source:
                    matches = _sha256(target) == hashlib.file_digest(source, "sha256").hexdigest()
        if not matches:
            raise runtime.TevRuntimeError("runtime_install_mismatch")


def install_runtime(progress: Progress | None = None) -> Path:
    """Verify a cached archive and existing extraction, or install once atomically.

    Only this explicit installer can download. A corrupt existing archive or
    extraction fails without replacing it or touching any running service.
    """
    progress = progress or Progress()
    with runtime.runtime_lock(time.monotonic() + DOWNLOAD_TIMEOUT):
        if not RUNTIME_ARCHIVE.exists():
            _download_archive(progress)
        if RUNTIME_ARCHIVE.stat().st_size > MAX_ARCHIVE_BYTES or _sha256(RUNTIME_ARCHIVE) != RUNTIME_SHA256:
            raise runtime.TevRuntimeError("runtime_hash_mismatch")
        version_dir = runtime.OLLAMA_BINARY.parent.parent
        with tarfile.open(RUNTIME_ARCHIVE, "r:gz") as archive:
            members = _archive_members(archive)
            if version_dir.exists():
                _verify_files(archive, members, runtime.OLLAMA_BINARY.parent)
            else:
                version_dir.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.TemporaryDirectory(prefix=".tev-install-", dir=version_dir.parent) as staging:
                    staged = Path(staging) / "runtime"
                    destination = staged / "bin"
                    destination.mkdir(parents=True)
                    archive.extractall(destination, members=members, filter="data")
                    _verify_files(archive, members, destination)
                    staged.rename(version_dir)
        receipt = {
            "version": runtime.OLLAMA_VERSION, "archive_sha256": RUNTIME_SHA256,
            "binary": str(runtime.OLLAMA_BINARY), "binary_sha256": _sha256(runtime.OLLAMA_BINARY),
            "verified_files": len(members),
        }
        temporary = INSTALL_RECEIPT.with_suffix(".tmp")
        temporary.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary.replace(INSTALL_RECEIPT)
    progress.emit("runtime_verified", terminal=True, version=runtime.OLLAMA_VERSION)
    return runtime.OLLAMA_BINARY


def verify_installed_model(model_id: str, *, base_url: str = runtime.TEV_BASE_URL) -> dict:
    """Compare the selected runner's installed leaf manifest with the catalog."""
    runtime.validate_tev_base_url(base_url)
    model = TEV_MODELS[model_id]
    with runtime.open_tev_api("/api/tags", base_url=base_url, timeout=5.0) as response:
        data = response.read(MAX_API_BYTES + 1)
    if len(data) > MAX_API_BYTES:
        raise runtime.TevRuntimeError("tev_response_limit")
    payload = json.loads(data)
    entries = payload.get("models") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        raise runtime.TevRuntimeError("tev_manifest_mismatch")
    matches = []
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("name", entry.get("model")) != model["tag"]:
            continue
        details = entry.get("details") or {}
        if not isinstance(details, dict) or details.get("runner", "llamacpp") != model["runner"]:
            continue
        matches.append(entry)
    digest = matches[0].get("digest") if len(matches) == 1 else None
    if not isinstance(digest, str) or digest.removeprefix("sha256:") != model["digest"]:
        raise runtime.TevRuntimeError("tev_manifest_mismatch")
    return matches[0]


def pull_model(model_id: str, *, base_url: str = runtime.TEV_BASE_URL, progress: Progress | None = None):
    """Pull one explicit size tag; never accept a user-supplied URL or latest tag."""
    runtime.validate_tev_base_url(base_url)
    model = TEV_MODELS[model_id]
    progress = progress or Progress()
    deadline = time.monotonic() + PULL_TIMEOUT
    success = False
    request = {"model": model["tag"], "runner": model["runner"], "stream": True}
    with runtime.open_tev_api("/api/pull", base_url=base_url, data=request, timeout=60.0) as response:
        for _ in range(100000):
            if time.monotonic() >= deadline:
                raise runtime.TevRuntimeError("tev_pull_timeout")
            line = response.readline(MAX_PROGRESS_LINE_BYTES + 1)
            if not line:
                break
            if len(line) > MAX_PROGRESS_LINE_BYTES:
                raise runtime.TevRuntimeError("tev_response_limit")
            event = json.loads(line)
            if not isinstance(event, dict) or "error" in event:
                raise runtime.TevRuntimeError("tev_pull_failed")
            if event.get("status") == "success":
                success = True
                break
            completed, total = event.get("completed", 0), event.get("total", 0)
            if type(completed) is int and type(total) is int and 0 <= completed <= total <= MAX_EXTRACTED_BYTES * 4:
                progress.emit("model_download", model=model_id, completed=completed, total=total)
    if not success:
        raise runtime.TevRuntimeError("tev_pull_incomplete")
    verify_installed_model(model_id, base_url=base_url)
    progress.emit("model_verified", terminal=True, model=model_id, digest=model["digest"], bytes=model["bytes"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, choices=[*TEV_MODELS, "all"])
    args = parser.parse_args(argv)
    progress = Progress()
    try:
        install_runtime(progress)
        base_url = runtime.ensure_tev_server()
        for model_id in TEV_MODELS if args.model == "all" else [args.model]:
            pull_model(model_id, base_url=base_url, progress=progress)
    except runtime.TevRuntimeError as exc:
        progress.emit("error", terminal=True, error=str(exc))
        return 1
    except (OSError, ValueError, tarfile.TarError):
        progress.emit("error", terminal=True, error="tev_install_failed")
        return 1
    progress.emit("complete", terminal=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
