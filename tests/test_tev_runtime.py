"""Offline lifecycle, ownership, archive and model-pin contracts."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import subprocess
import tarfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from rime_jev import tev_runtime as runtime
from rime_jev.tev_models import TEV_MODELS


_SCRIPT = Path(__file__).resolve().parents[1] / "scripts/download_tev.py"
_SPEC = importlib.util.spec_from_file_location("download_tev", _SCRIPT)
download = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(download)
STARTED = "Sun Oct 11 12:00:00 2026"
PID = 45678


@pytest.fixture(autouse=True)
def isolated(tmp_path, monkeypatch):
    """No test can launch a process, open a socket, or touch the real model store."""
    root = tmp_path.resolve()
    runtime_root = root / "work/runtime"
    for name, value in {
        "REPO_ROOT": root,
        "RUNTIME_ROOT": runtime_root,
        "OLLAMA_BINARY": runtime_root / "ollama/0.40.3/bin/ollama",
        "OLLAMA_MODELS": root / "work/models/ollama",
        "PID_RECEIPT_PATH": runtime_root / "tev-ollama.json",
        "LOCK_PATH": runtime_root / "tev-ollama.lock",
        "_CHILDREN": [],
    }.items():
        monkeypatch.setattr(runtime, name, value)
    monkeypatch.setattr(download, "RUNTIME_ARCHIVE", runtime_root / "downloads/ollama-0.40.3-darwin.tgz")
    monkeypatch.setattr(download, "INSTALL_RECEIPT", runtime_root / "ollama-0.40.3-install.json")
    monkeypatch.setattr(runtime.subprocess, "Popen", Mock(side_effect=AssertionError("live process forbidden")))
    monkeypatch.setattr(runtime.subprocess, "run", Mock(side_effect=AssertionError("live inspection forbidden")))
    monkeypatch.setattr(runtime.socket, "socket", Mock(side_effect=AssertionError("live socket forbidden")))
    monkeypatch.setattr(runtime.urllib.request, "build_opener", Mock(side_effect=AssertionError("live network forbidden")))


@pytest.fixture
def binary():
    runtime.OLLAMA_BINARY.parent.mkdir(parents=True)
    runtime.OLLAMA_BINARY.write_bytes(b"pinned executable fixture")
    runtime.OLLAMA_BINARY.chmod(0o755)
    return runtime.OLLAMA_BINARY


@pytest.fixture
def managed(binary, monkeypatch):
    started = Mock(return_value=STARTED)
    listeners = Mock(return_value={(PID, "127.0.0.1:11435")})
    ready = Mock(return_value=True)
    monkeypatch.setattr(runtime, "_process_started", started)
    monkeypatch.setattr(runtime, "_listeners", listeners)
    monkeypatch.setattr(runtime, "_ready", ready)
    runtime._write_receipt(PID, STARTED)
    return SimpleNamespace(started=started, listeners=listeners, ready=ready)


def _archive(monkeypatch, *, unsafe: str | None = None, kind=tarfile.REGTYPE):
    download.RUNTIME_ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(download.RUNTIME_ARCHIVE, "w:gz") as archive:
        for name, data in [("ollama", b"verified executable"), ("libbase.0.dylib", b"verified library")]:
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o755
            archive.addfile(entry, io.BytesIO(data))
        entry = tarfile.TarInfo("libbase.dylib")
        entry.type, entry.linkname = tarfile.SYMTYPE, "libbase.0.dylib"
        archive.addfile(entry)
        directory = tarfile.TarInfo("mlx_metal_v4")
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        if unsafe is not None:
            entry = tarfile.TarInfo(unsafe)
            entry.type = kind
            if kind in {tarfile.SYMTYPE, tarfile.LNKTYPE}:
                entry.linkname = "../../outside"
            archive.addfile(entry)
    monkeypatch.setattr(download, "RUNTIME_SHA256", download._sha256(download.RUNTIME_ARCHIVE))
    return download.RUNTIME_ARCHIVE


def _tags(model_id="tev-0.8b", *, digest=None):
    model = TEV_MODELS[model_id]
    return {"models": [{"name": model["tag"], "digest": model["digest"] if digest is None else digest,
                        "details": {"runner": model["runner"]}}]}


def _json_response(value):
    return io.BytesIO(json.dumps(value).encode())


def test_missing_runtime_never_downloads_or_launches():
    with pytest.raises(runtime.TevRuntimeError, match="tev_runtime_not_installed"):
        runtime.ensure_tev_server()
    runtime.subprocess.Popen.assert_not_called()


@pytest.mark.parametrize("timeout", [0, -1, float("inf"), float("nan"), 31])
def test_startup_budget_is_bounded(timeout):
    with pytest.raises(runtime.TevRuntimeError, match="invalid_tev_startup_timeout"):
        runtime.ensure_tev_server(startup_timeout=timeout)


def test_symlink_to_another_binary_is_refused(binary):
    real = binary.with_name("other-ollama")
    binary.rename(real)
    binary.symlink_to(real.name)
    with pytest.raises(runtime.TevRuntimeError, match="tev_runtime_not_installed"):
        runtime.ensure_tev_server()


def test_owned_healthy_server_reused_without_launch(managed):
    assert runtime.ensure_tev_server() == "http://127.0.0.1:11435"
    runtime.subprocess.Popen.assert_not_called()


@pytest.mark.parametrize("listener", [
    (9876, "127.0.0.1:11435"), (PID, "*:11435"), (PID, "0.0.0.0:11435"),
    (PID, "[::]:11435"), (PID, "192.168.1.2:11435"),
])
def test_unknown_owner_and_all_interfaces_refused(managed, listener):
    managed.listeners.return_value = {listener}
    with pytest.raises(runtime.TevRuntimeError, match="tev_port_unowned"):
        runtime.ensure_tev_server()
    runtime.subprocess.Popen.assert_not_called()


@pytest.mark.parametrize("receipt_state", ["missing", "bad_binary", "reused_pid"])
def test_port_cannot_be_adopted_without_matching_receipt(managed, receipt_state):
    if receipt_state == "missing":
        runtime.PID_RECEIPT_PATH.unlink()
    elif receipt_state == "bad_binary":
        data = json.loads(runtime.PID_RECEIPT_PATH.read_text())
        data["binary"] = "/usr/local/bin/ollama"
        runtime.PID_RECEIPT_PATH.write_text(json.dumps(data))
    else:
        managed.started.return_value = "Sun Oct 11 12:01:00 2026"
    with pytest.raises(runtime.TevRuntimeError, match="tev_port_unowned"):
        runtime.ensure_tev_server()
    runtime.subprocess.Popen.assert_not_called()


def _allow_launch(monkeypatch):
    child = Mock(pid=PID)
    child.poll.return_value = None
    popen = Mock(return_value=child)
    socket = Mock()
    socket.__enter__ = Mock(return_value=socket)
    socket.__exit__ = Mock(return_value=False)
    monkeypatch.setattr(runtime.subprocess, "Popen", popen)
    monkeypatch.setattr(runtime.socket, "socket", Mock(return_value=socket))
    return child, popen, socket


def test_launch_has_fixed_environment_and_receipt(binary, monkeypatch):
    child, popen, socket = _allow_launch(monkeypatch)
    monkeypatch.setenv("HOME", "/original-home")
    monkeypatch.setenv("OLLAMA_HOST", "0.0.0.0:11434")
    monkeypatch.setenv("OLLAMA_MODELS", "/other-store")
    monkeypatch.setenv("OLLAMA_DEBUG", "1")
    monkeypatch.setattr(runtime, "_listeners", Mock(side_effect=[set(), {(PID, "127.0.0.1:11435")}]))
    monkeypatch.setattr(runtime, "_process_started", Mock(return_value=STARTED))
    monkeypatch.setattr(runtime, "_ready", Mock(return_value=True))
    assert runtime.ensure_tev_server() == runtime.TEV_BASE_URL
    args, options = popen.call_args
    assert args == ([str(binary), "serve"],)
    assert options["env"]["HOME"] == "/original-home"
    assert {k: v for k, v in options["env"].items() if k.startswith("OLLAMA_")} == {
        "OLLAMA_HOST": "127.0.0.1:11435", "OLLAMA_MODELS": str(runtime.OLLAMA_MODELS),
        "OLLAMA_NO_CLOUD": "1", "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_NUM_PARALLEL": "1",
        "OLLAMA_MAX_QUEUE": "1", "OLLAMA_CONTEXT_LENGTH": "2048", "OLLAMA_KEEP_ALIVE": "10m",
    }
    assert all(options[key] == subprocess.DEVNULL for key in ("stdin", "stdout", "stderr"))
    assert options["start_new_session"] and options["close_fds"]
    socket.bind.assert_called_once_with(("127.0.0.1", 11435))
    assert runtime._read_receipt() == {
        "pid": PID, "binary": str(binary), "base_url": runtime.TEV_BASE_URL,
        "models": str(runtime.OLLAMA_MODELS), "version": "0.40.3", "started": STARTED,
    }
    assert runtime.PID_RECEIPT_PATH.stat().st_mode & 0o777 == 0o600
    child.kill.assert_not_called()
    child.terminate.assert_not_called()


def test_busy_bind_fails_without_launch(binary, monkeypatch):
    _, popen, socket = _allow_launch(monkeypatch)
    socket.bind.side_effect = OSError("busy")
    monkeypatch.setattr(runtime, "_listeners", Mock(return_value=set()))
    with pytest.raises(runtime.TevRuntimeError, match="tev_port_unowned"):
        runtime.ensure_tev_server()
    popen.assert_not_called()


def test_child_exit_fails_without_kill(binary, monkeypatch):
    child, _, _ = _allow_launch(monkeypatch)
    child.poll.return_value = 1
    monkeypatch.setattr(runtime, "_listeners", Mock(return_value=set()))
    with pytest.raises(runtime.TevRuntimeError, match="tev_start_failed"):
        runtime.ensure_tev_server()
    child.kill.assert_not_called()


def test_process_change_during_startup_is_refused(managed):
    managed.started.side_effect = [STARTED, None]
    with pytest.raises(runtime.TevRuntimeError, match="tev_process_changed"):
        runtime.ensure_tev_server()


def test_port_race_after_spawn_is_refused(binary, monkeypatch):
    child, _, _ = _allow_launch(monkeypatch)
    monkeypatch.setattr(runtime, "_process_started", Mock(return_value=STARTED))
    monkeypatch.setattr(runtime, "_listeners", Mock(side_effect=[set(), {(99, "127.0.0.1:11435")}]))
    with pytest.raises(runtime.TevRuntimeError, match="tev_port_unowned"):
        runtime.ensure_tev_server()
    child.kill.assert_not_called()


def test_not_ready_has_bounded_wait_and_reusable_receipt(managed):
    managed.ready.return_value = False
    before = time.monotonic()
    with pytest.raises(runtime.TevRuntimeError, match="tev_startup_timeout"):
        runtime.ensure_tev_server(startup_timeout=0.03)
    assert time.monotonic() - before < 0.5
    assert runtime._read_receipt()["pid"] == PID


def test_flock_contention_is_bounded():
    deadline = time.monotonic() + 1
    with runtime.runtime_lock(deadline):
        with pytest.raises(runtime.TevRuntimeError, match="tev_startup_timeout"):
            with runtime.runtime_lock(time.monotonic() + 0.02):
                pytest.fail("contended lock acquired")
    with runtime.runtime_lock(time.monotonic() + 1):
        pass


def test_concurrent_ensure_spawns_once(binary, monkeypatch):
    _, popen, _ = _allow_launch(monkeypatch)
    monkeypatch.setattr(runtime, "_process_started", Mock(return_value=STARTED))
    monkeypatch.setattr(runtime, "_ready", Mock(return_value=True))
    monkeypatch.setattr(runtime, "_listeners", lambda deadline: (
        {(PID, "127.0.0.1:11435")} if popen.called else set()
    ))
    outcomes = []
    def ensure():
        outcomes.append(runtime.ensure_tev_server())
    threads = [threading.Thread(target=ensure) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=2)
        assert not thread.is_alive()
    assert outcomes == [runtime.TEV_BASE_URL] * 2
    popen.assert_called_once()


@pytest.mark.parametrize("body", ["not-json", "[]", "x" * 4097, '{"pid":true}', '{"pid":1}'])
def test_invalid_receipt_ignored(body):
    runtime.RUNTIME_ROOT.mkdir(parents=True)
    runtime.PID_RECEIPT_PATH.write_text(body)
    assert runtime._read_receipt() is None


def test_process_identity_checks_uid_command_birth_and_executable(binary, monkeypatch):
    run = Mock(side_effect=[
        SimpleNamespace(returncode=0, stdout=f"{os.getuid()} {STARTED} {binary} serve\n"),
        SimpleNamespace(returncode=0, stdout=f"p{PID}\nftxt\nn{binary}\n"),
    ])
    monkeypatch.setattr(runtime.subprocess, "run", run)
    assert runtime._process_started(PID, time.monotonic() + 3) == STARTED
    assert all(call.kwargs["timeout"] <= 1 for call in run.call_args_list)


@pytest.mark.parametrize("output,code", [("", 1), ("garbled", 0), (f"999999 {STARTED} /other/ollama serve", 0)])
def test_foreign_process_identity_rejected(output, code, monkeypatch):
    monkeypatch.setattr(runtime.subprocess, "run", Mock(return_value=SimpleNamespace(returncode=code, stdout=output)))
    assert runtime._process_started(PID, time.monotonic() + 1) is None


def test_command_alone_does_not_prove_executable(binary, monkeypatch):
    monkeypatch.setattr(runtime.subprocess, "run", Mock(side_effect=[
        SimpleNamespace(returncode=0, stdout=f"{os.getuid()} {STARTED} {binary} serve"),
        SimpleNamespace(returncode=0, stdout="n/usr/local/bin/ollama\n"),
    ]))
    assert runtime._process_started(PID, time.monotonic() + 1) is None


def test_process_inspection_timeout_is_fixed_error(monkeypatch):
    monkeypatch.setattr(runtime.subprocess, "run", Mock(side_effect=subprocess.TimeoutExpired("ps", 1)))
    with pytest.raises(runtime.TevRuntimeError, match="tev_process_inspection_timeout"):
        runtime._process_started(PID, time.monotonic() + 1)


@pytest.mark.parametrize("output,code,expected", [
    ("", 1, set()), ("p45678\nn127.0.0.1:11435\n", 0, {(45678, "127.0.0.1:11435")}),
    ("p12\nn*:11435\np34\nn[::1]:11435\n", 0, {(12, "*:11435"), (34, "[::1]:11435")}),
])
def test_port_inspection_parses_all_listeners(output, code, expected, monkeypatch):
    monkeypatch.setattr(runtime.subprocess, "run", Mock(return_value=SimpleNamespace(returncode=code, stdout=output)))
    assert runtime._listeners(time.monotonic() + 1) == expected


@pytest.mark.parametrize("output,code", [("", 2), ("punknown\n", 0), ("n127.0.0.1:11435\n", 0)])
def test_uncertain_port_inspection_fails_closed(output, code, monkeypatch):
    monkeypatch.setattr(runtime.subprocess, "run", Mock(return_value=SimpleNamespace(returncode=code, stdout=output)))
    with pytest.raises(runtime.TevRuntimeError, match="tev_port_inspection_failed"):
        runtime._listeners(time.monotonic() + 1)


@pytest.mark.parametrize("url", [
    "http://0.0.0.0:11435", "http://example.com:11435", "http://127.0.0.1:11434",
    "http://127.0.0.1:11436", "http://localhost:11435", "http://127.0.0.1:11435@evil.test",
    "http://127.0.0.1:11435/", "https://127.0.0.1:11435",
])
def test_noncanonical_api_urls_refused_before_io(url):
    with pytest.raises(runtime.TevRuntimeError, match="invalid_tev_endpoint"):
        runtime.open_tev_api("/api/tags", base_url=url)
    with pytest.raises(runtime.TevRuntimeError, match="invalid_tev_endpoint"):
        download.pull_model("tev-0.8b", base_url=url)


def test_private_http_disables_proxies_and_redirects(monkeypatch):
    opener = Mock()
    build = Mock(return_value=opener)
    monkeypatch.setattr(runtime.urllib.request, "build_opener", build)
    runtime.open_tev_api("/api/pull", data={"model": "tev1:4b"}, timeout=2)
    handlers = build.call_args.args
    assert handlers[0].proxies == {}
    assert isinstance(handlers[1], runtime._NoRedirect)
    request = opener.open.call_args.args[0]
    assert request.full_url == "http://127.0.0.1:11435/api/pull"
    assert json.loads(request.data) == {"model": "tev1:4b"}
    with pytest.raises(runtime.TevRuntimeError, match="tev_redirect_refused"):
        handlers[1].redirect_request(request, None, 302, "", {}, "https://evil.test")
    with pytest.raises(runtime.TevRuntimeError, match="invalid_tev_api_path"):
        runtime.open_tev_api("//evil.test")


@pytest.mark.parametrize("body,expected", [(b'{"version":"0.40.3"}', True), (b"invalid", False)])
def test_ready_only_accepts_pinned_version(body, expected, monkeypatch):
    monkeypatch.setattr(runtime, "open_tev_api", Mock(return_value=io.BytesIO(body)))
    assert runtime._ready(time.monotonic() + 1) is expected


@pytest.mark.parametrize("body", [b'{"version":"0.33.2"}', b"[]", b"x" * 4097])
def test_wrong_version_and_oversize_rejected(body, monkeypatch):
    monkeypatch.setattr(runtime, "open_tev_api", Mock(return_value=io.BytesIO(body)))
    with pytest.raises(runtime.TevRuntimeError, match="tev_version_mismatch"):
        runtime._ready(time.monotonic() + 1)


def test_network_not_ready(monkeypatch):
    monkeypatch.setattr(runtime, "open_tev_api", Mock(side_effect=urllib.error.URLError("offline")))
    assert runtime._ready(time.monotonic() + 1) is False


def test_bad_cached_hash_preserved_and_never_redownloaded(monkeypatch):
    path = _archive(monkeypatch)
    original = path.read_bytes()
    monkeypatch.setattr(download, "RUNTIME_SHA256", "0" * 64)
    with pytest.raises(runtime.TevRuntimeError, match="runtime_hash_mismatch"):
        download.install_runtime()
    assert path.read_bytes() == original
    assert not runtime.OLLAMA_BINARY.exists()


def test_cached_archive_installs_flat_bin_and_reuses_existing(monkeypatch):
    path = _archive(monkeypatch)
    assert download.install_runtime() == runtime.OLLAMA_BINARY
    binary = runtime.OLLAMA_BINARY
    before = binary.stat()
    assert binary.read_bytes() == b"verified executable"
    assert (binary.parent / "libbase.dylib").is_symlink()
    assert (binary.parent / "libbase.dylib").read_bytes() == b"verified library"
    monkeypatch.setattr(tarfile.TarFile, "extractall", Mock(side_effect=AssertionError("duplicate extraction")))
    assert download.install_runtime() == binary
    assert binary.stat().st_ino == before.st_ino
    assert binary.stat().st_mtime_ns == before.st_mtime_ns
    receipt = json.loads(download.INSTALL_RECEIPT.read_text())
    assert receipt["archive_sha256"] == download._sha256(path)
    assert receipt["binary_sha256"] == download._sha256(binary)
    assert receipt["verified_files"] == 4


def test_existing_runtime_mismatch_fails_without_replacement(monkeypatch):
    _archive(monkeypatch)
    download.install_runtime()
    runtime.OLLAMA_BINARY.write_bytes(b"tampered")
    with pytest.raises(runtime.TevRuntimeError, match="runtime_install_mismatch"):
        download.install_runtime()
    assert runtime.OLLAMA_BINARY.read_bytes() == b"tampered"


def test_explicit_installer_downloads_only_when_cache_missing(monkeypatch):
    archive = _archive(monkeypatch)
    content = archive.read_bytes()
    archive.unlink()
    response = io.BytesIO(content)
    response.geturl = lambda: download.RUNTIME_URL
    opener = Mock()
    opener.open.return_value = response
    monkeypatch.setattr(download.urllib.request, "build_opener", Mock(return_value=opener))
    assert download.install_runtime() == runtime.OLLAMA_BINARY
    assert archive.read_bytes() == content
    opener.open.assert_called_once()


@pytest.mark.parametrize("name,kind", [
    ("../escaped", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
    ("ollama", tarfile.REGTYPE), ("device", tarfile.CHRTYPE),
    ("escape-link", tarfile.SYMTYPE), ("escape-hardlink", tarfile.LNKTYPE),
])
def test_unsafe_tar_rejected_without_install(name, kind, monkeypatch):
    _archive(monkeypatch, unsafe=name, kind=kind)
    with pytest.raises(runtime.TevRuntimeError, match="unsafe_runtime_archive"):
        download.install_runtime()
    assert not runtime.OLLAMA_BINARY.exists()


def test_existing_library_symlink_escape_refused(monkeypatch, tmp_path):
    _archive(monkeypatch)
    download.install_runtime()
    library = runtime.OLLAMA_BINARY.parent / "libbase.dylib"
    library.unlink()
    library.symlink_to(tmp_path / "outside")
    with pytest.raises(runtime.TevRuntimeError, match="unsafe_runtime_destination"):
        download.install_runtime()


@pytest.mark.parametrize("url", [
    "http://github.com/ollama/ollama/releases/download/v0.40.3/ollama-darwin.tgz",
    "https://github.com/other/release.tgz", "https://release-assets.githubusercontent.com.evil.test/a",
    "https://evil.test/ollama.tgz", "https://user:password@release-assets.githubusercontent.com/a",
    "https://release-assets.githubusercontent.com:444/a", "https://release-assets.githubusercontent.com:bad/a",
])
def test_runtime_download_refuses_untrusted_urls(url):
    with pytest.raises(runtime.TevRuntimeError, match="untrusted_runtime_url"):
        download._official_url(url)


def test_official_redirect_and_download_are_verified(monkeypatch):
    content = b"compressed runtime fixture"
    monkeypatch.setattr(download, "RUNTIME_SHA256", hashlib.sha256(content).hexdigest())
    response = io.BytesIO(content)
    response.geturl = lambda: "https://release-assets.githubusercontent.com/github-production-release-asset/x"
    opener = Mock()
    opener.open.return_value = response
    monkeypatch.setattr(download.urllib.request, "build_opener", Mock(return_value=opener))
    download._download_archive(download.Progress())
    assert download.RUNTIME_ARCHIVE.read_bytes() == content
    assert not download.RUNTIME_ARCHIVE.with_suffix(".part").exists()
    redirect = download._OfficialRedirect()
    request = urllib.request.Request(download.RUNTIME_URL)
    assert redirect.redirect_request(request, None, 302, "", {}, response.geturl()).full_url == response.geturl()
    with pytest.raises(runtime.TevRuntimeError, match="untrusted_runtime_url"):
        redirect.redirect_request(request, None, 302, "", {}, "http://evil.test/a")


@pytest.mark.parametrize("limit", [False, True])
def test_runtime_download_bad_hash_or_size_cleans_partial(monkeypatch, limit):
    response = io.BytesIO(b"incorrect runtime")
    response.geturl = lambda: download.RUNTIME_URL
    opener = Mock()
    opener.open.return_value = response
    monkeypatch.setattr(download.urllib.request, "build_opener", Mock(return_value=opener))
    if limit:
        monkeypatch.setattr(download, "MAX_ARCHIVE_BYTES", 1)
    with pytest.raises(runtime.TevRuntimeError, match="runtime_download_limit" if limit else "runtime_hash_mismatch"):
        download._download_archive(download.Progress())
    assert not download.RUNTIME_ARCHIVE.exists()
    assert not download.RUNTIME_ARCHIVE.with_suffix(".part").exists()


@pytest.mark.parametrize("model_id", TEV_MODELS)
def test_pull_pins_tag_runner_and_verifies_digest(model_id, monkeypatch, capsys):
    stream = io.BytesIO(b'{"status":"pulling hidden text","completed":5,"total":10}\n{"status":"success"}\n')
    api = Mock(side_effect=[stream, _json_response(_tags(model_id))])
    monkeypatch.setattr(runtime, "open_tev_api", api)
    download.pull_model(model_id)
    assert api.call_args_list[0].args == ("/api/pull",)
    assert api.call_args_list[0].kwargs["data"] == {
        "model": TEV_MODELS[model_id]["tag"], "runner": TEV_MODELS[model_id]["runner"], "stream": True,
    }
    output = capsys.readouterr().out
    assert "hidden text" not in output
    assert json.loads(output.splitlines()[-1])["digest"] == TEV_MODELS[model_id]["digest"]


@pytest.mark.parametrize("digest", ["bad", "", "0" * 64, 123])
def test_installed_manifest_mismatch_rejected(digest, monkeypatch):
    monkeypatch.setattr(runtime, "open_tev_api", Mock(return_value=_json_response(_tags(digest=digest))))
    with pytest.raises(runtime.TevRuntimeError, match="tev_manifest_mismatch"):
        download.verify_installed_model("tev-0.8b")


def test_manifest_variant_matches_selected_runner(monkeypatch):
    payload = _tags()
    selected = TEV_MODELS["tev-0.8b"]["runner"]
    other = "llamacpp" if selected == "mlx" else "mlx"
    payload["models"].insert(0, {"name": "tev1:0.8b", "digest": "other", "details": {"runner": other}})
    payload["models"].insert(0, {"name": "another:1"})
    payload["models"].insert(0, "invalid")
    payload["models"][3]["digest"] = "sha256:" + TEV_MODELS["tev-0.8b"]["digest"]
    monkeypatch.setattr(runtime, "open_tev_api", Mock(return_value=_json_response(payload)))
    assert download.verify_installed_model("tev-0.8b")["details"]["runner"] == selected


@pytest.mark.parametrize("runner", ["mlx", "llamacpp"])
def test_explicit_runner_selects_corresponding_leaf(runner, monkeypatch):
    monkeypatch.setitem(TEV_MODELS, "tev-0.8b", {**TEV_MODELS["tev-0.8b"], "runner": runner})
    api = Mock(side_effect=[io.BytesIO(b'{"status":"success"}\n'), _json_response(_tags())])
    monkeypatch.setattr(runtime, "open_tev_api", api)
    download.pull_model("tev-0.8b")
    assert api.call_args_list[0].kwargs["data"]["runner"] == runner


@pytest.mark.parametrize("payload", [[], {"models": None}, {"models": []}])
def test_missing_or_invalid_manifest_rejected(payload, monkeypatch):
    monkeypatch.setattr(runtime, "open_tev_api", Mock(return_value=_json_response(payload)))
    with pytest.raises(runtime.TevRuntimeError, match="tev_manifest_mismatch"):
        download.verify_installed_model("tev-0.8b")


@pytest.mark.parametrize("body,error", [
    (b'{"error":"secret upstream text"}\n', "tev_pull_failed"),
    (b"[]\n", "tev_pull_failed"), (b"", "tev_pull_incomplete"),
    (b"x" * (download.MAX_PROGRESS_LINE_BYTES + 1), "tev_response_limit"),
])
def test_pull_error_or_unbounded_output_not_accepted(body, error, monkeypatch, capsys):
    monkeypatch.setattr(runtime, "open_tev_api", Mock(return_value=io.BytesIO(body)))
    with pytest.raises(runtime.TevRuntimeError, match=error):
        download.pull_model("tev-0.8b")
    assert "secret upstream" not in capsys.readouterr().out


def test_pull_success_with_wrong_manifest_is_not_verified(monkeypatch, capsys):
    api = Mock(side_effect=[io.BytesIO(b'{"status":"success"}\n'), _json_response(_tags(digest="bad"))])
    monkeypatch.setattr(runtime, "open_tev_api", api)
    with pytest.raises(runtime.TevRuntimeError, match="tev_manifest_mismatch"):
        download.pull_model("tev-0.8b")
    assert "model_verified" not in capsys.readouterr().out


def test_progress_output_is_bounded_and_terminal_retained(monkeypatch, capsys):
    clock = iter(range(1000))
    monkeypatch.setattr(download.time, "monotonic", lambda: next(clock))
    progress = download.Progress()
    for value in range(500):
        progress.emit("model_download", completed=value)
    for _ in range(5):
        progress.emit("complete", terminal=True)
    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 204
    assert all(len(line) < 256 for line in lines)
    assert json.loads(lines[-1])["stage"] == "complete"


def test_cli_explicit_all_installs_then_pulls_both(monkeypatch, capsys):
    events = []
    monkeypatch.setattr(download, "install_runtime", lambda progress: events.append("install"))
    monkeypatch.setattr(runtime, "ensure_tev_server", lambda: runtime.TEV_BASE_URL)
    monkeypatch.setattr(download, "pull_model", lambda model_id, **kwargs: events.append(model_id))
    assert download.main(["--model", "all"]) == 0
    assert events == ["install", "tev-0.8b", "tev-4b"]
    assert json.loads(capsys.readouterr().out)["stage"] == "complete"


def test_cli_failure_has_bounded_json_without_upstream_details(monkeypatch, capsys):
    monkeypatch.setattr(download, "install_runtime", Mock(side_effect=OSError("private upstream error")))
    assert download.main(["--model", "tev-4b"]) == 1
    assert json.loads(capsys.readouterr().out) == {"stage": "error", "error": "tev_install_failed"}


def test_cli_preserves_fixed_integrity_error_code(monkeypatch, capsys):
    monkeypatch.setattr(download, "install_runtime", Mock(side_effect=runtime.TevRuntimeError("runtime_hash_mismatch")))
    assert download.main(["--model", "tev-0.8b"]) == 1
    assert json.loads(capsys.readouterr().out) == {"stage": "error", "error": "runtime_hash_mismatch"}


@pytest.mark.parametrize("args", [[], ["--model", "latest"], ["--model", "tev1"]])
def test_cli_requires_explicit_supported_choice(args):
    with pytest.raises(SystemExit) as error:
        download.main(args)
    assert error.value.code == 2
