from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

from rime_jev import runtime, tev_provider
from rime_jev.providers import JEV_MODEL_ID, LOCAL_MODEL_ID
from rime_jev.tev_models import TEV_MODELS
from test_runtime import call, payload, wait_for_socket
from test_tev_provider import Response, Session


@pytest.mark.parametrize("provider_id", ["tev-0.8b", "tev-4b"])
def test_cli_constructs_selected_tev_without_credentials_or_tt(monkeypatch, provider_id):
    selected = []

    original = tev_provider.TevProvider

    def construct(selected_id):
        selected.append(selected_id)
        return original(selected_id, session=Session(), server_manager=lambda: tev_provider.DEFAULT_BASE_URL)

    class Server:
        def __init__(self, path, provider):
            self.provider = provider
            assert path == "/unused/mock.sock"

        def serve_forever(self):
            self.provider.start()
            assert self.provider.wait_until_ready(1)
            health = self.provider.health()
            assert health.provider == provider_id and health.model == TEV_MODELS[provider_id]["tag"]

        def stop(self):
            self.provider.shutdown()

    monkeypatch.setattr(runtime, "RuntimeServer", Server)
    monkeypatch.setattr(tev_provider, "TevProvider", construct)
    monkeypatch.setattr(runtime, "LocalProvider", lambda *args: pytest.fail("TT selected for Tev"))
    monkeypatch.setattr(runtime, "JevProvider", lambda *args: pytest.fail("Cloud selected for Tev"))
    assert runtime.main(["--socket", "/unused/mock.sock", "--provider", provider_id]) == 0
    assert selected == [provider_id]


@pytest.mark.parametrize("provider_id,argument,model", [
    ("local", "--model-path", LOCAL_MODEL_ID), ("jev", "--vault-ref", JEV_MODEL_ID),
])
def test_existing_cli_provider_selection_unchanged(monkeypatch, provider_id, argument, model):
    selected = []

    class Provider:
        provider_name = provider_id
        model_name = model

        def __init__(self, value):
            selected.append(value)

    class Server:
        def __init__(self, path, provider):
            assert provider.provider_name == provider_id
            assert provider.model_name == model

        def serve_forever(self):
            pass

        def stop(self):
            pass

    monkeypatch.setattr(runtime, "RuntimeServer", Server)
    monkeypatch.setattr(runtime, "LocalProvider" if provider_id == "local" else "JevProvider", Provider)
    monkeypatch.setattr(tev_provider, "TevProvider", lambda *args: pytest.fail("Tev selected for existing mode"))
    assert runtime.main(["--socket", "/unused/mock.sock", "--provider", provider_id, argument, "fixture"]) == 0
    assert selected == ["fixture"]


def test_switch_on_same_socket_keeps_fixed_identity_and_cleans_selected_tag():
    with tempfile.TemporaryDirectory(prefix="rj-tev-", dir="/tmp") as directory:
        path = Path(directory) / "runtime.sock"
        for provider_id, config in TEV_MODELS.items():
            session = Session()
            provider = tev_provider.TevProvider(
                provider_id, session=session, server_manager=lambda: tev_provider.DEFAULT_BASE_URL,
            )
            server = runtime.RuntimeServer(path, provider)
            thread = server.run_in_thread()
            try:
                wait_for_socket(path)
                assert provider.wait_until_ready(1)
                health = call(path, {"id": "health", "op": "health"})
                assert health["model"] == config["tag"] and health["provider"] == provider_id
                request = payload()
                request.update({"provider": "jev", "model": "foreign-model"})
                result = call(path, request)
                assert result["model"] == config["tag"] and result["provider"] == provider_id
                assert result["choice_id"] == "c1"
                assert result["probabilities"] == {"c1": 1.0, "none": 0.0}
                shutdown = call(path, {"id": "stop", "op": "shutdown"})
                assert shutdown["model"] == config["tag"] and shutdown["provider"] == provider_id
                thread.join(2)
                assert not thread.is_alive() and not path.exists()
                assert session.unloads == [{"model": config["tag"], "keep_alive": 0, "stream": False}]
            finally:
                server.stop()
                thread.join(2)


@pytest.mark.parametrize("provider_id", ["tev-0.8b", "tev-4b"])
def test_idle_unload_exits_tev_listener(provider_id):
    with tempfile.TemporaryDirectory(prefix="rj-tev-idle-", dir="/tmp") as directory:
        path = Path(directory) / "runtime.sock"
        provider = tev_provider.TevProvider(
            provider_id, session=Session(), server_manager=lambda: tev_provider.DEFAULT_BASE_URL,
        )
        server = runtime.RuntimeServer(path, provider)
        thread = server.run_in_thread()
        try:
            wait_for_socket(path)
            assert provider.wait_until_ready(1)
            assert provider.unload_if_idle(now=10**10)
            thread.join(2)
            assert not thread.is_alive() and not path.exists()
            assert provider.health().error == "runtime_closed"
        finally:
            server.stop()
            thread.join(2)


def test_shutdown_keeps_socket_and_serving_thread_until_selected_model_unloaded():
    import threading

    entered, release, concurrent_done = threading.Event(), threading.Event(), threading.Event()
    results = []
    with tempfile.TemporaryDirectory(prefix="rj-tev-stop-", dir="/tmp") as directory:
        path = Path(directory) / "runtime.sock"
        session = Session()

        def callback(method, url, body, kwargs):
            if url.endswith("/api/generate"):
                entered.set()
                assert release.wait(2)

        session.callback = callback
        provider = tev_provider.TevProvider(
            "tev-4b", session=session, server_manager=lambda: tev_provider.DEFAULT_BASE_URL,
        )
        server = runtime.RuntimeServer(path, provider)
        thread = server.run_in_thread()
        concurrent = None
        try:
            wait_for_socket(path)
            assert provider.wait_until_ready(1)
            assert call(path, {"op": "shutdown"})["model"] == "tev1:4b"
            assert entered.wait(1)
            for request in ({"op": "health"}, payload()):
                response = call(path, request)
                assert response["status"] == "unavailable" and response["error"] == "runtime_closed"
            assert len(session.calls) == 3  # Tags, warmup, selected-tag unload; no inference.
            with pytest.raises(RuntimeError, match="already running"):
                runtime.RuntimeServer(path, provider).start()

            def stop_again():
                results.append(server.stop())
                concurrent_done.set()

            concurrent = threading.Thread(target=stop_again)
            concurrent.start()
            assert not concurrent_done.wait(0.3)
            assert path.exists() and thread.is_alive()
            release.set()
            concurrent.join(2)
            thread.join(2)
            assert concurrent_done.is_set() and not thread.is_alive()
            assert results == [True] and server.stop() is True
            assert not path.exists() and session.closed
            assert session.unloads == [{"model": "tev1:4b", "keep_alive": 0, "stream": False}]
        finally:
            release.set()
            server.stop()
            thread.join(2)
            if concurrent is not None:
                concurrent.join(2)


def test_failed_tev_unload_keeps_runtime_reachable_until_explicit_retry():
    with tempfile.TemporaryDirectory(prefix="rj-tev-retry-", dir="/tmp") as directory:
        path = Path(directory) / "runtime.sock"
        session = Session()
        provider = tev_provider.TevProvider(
            "tev-4b", session=session, server_manager=lambda: tev_provider.DEFAULT_BASE_URL,
        )
        server = runtime.RuntimeServer(path, provider)
        thread = server.run_in_thread()
        try:
            wait_for_socket(path)
            assert provider.wait_until_ready(1)
            session.callback = lambda *args: Response(status=500)
            assert server.stop() is False
            assert path.exists() and thread.is_alive() and server.is_running
            assert not server._shutdown_complete.is_set() and not session.closed
            for request in ({"op": "health"}, payload()):
                assert call(path, request)["error"] == "runtime_closed"
            with pytest.raises(RuntimeError, match="already running"):
                runtime.RuntimeServer(path, provider).start()
            assert len(session.unloads) == 1
            session.callback = None
            assert call(path, {"op": "shutdown"})["status"] == "ready"
            thread.join(2)
            assert not thread.is_alive() and not path.exists() and session.closed
            assert session.unloads == [{"model": "tev1:4b", "keep_alive": 0, "stream": False}] * 2
        finally:
            session.callback = None
            server.stop()
            thread.join(2)
