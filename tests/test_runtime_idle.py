import tempfile,time
from pathlib import Path
import pytest
from rime_jev.runtime import RuntimeServer
from rime_jev.providers import ProviderResult

class IdleProvider:
    provider_name='local'
    model_name='fixture'
    status='ready'
    closed=False
    def start(self): pass
    def health(self):return ProviderResult(status=self.status,provider='local',model='fixture')
    def shutdown(self):self.closed=True

def test_idle_unload_exits_listener_without_an_extra_client_request():
    with tempfile.TemporaryDirectory(prefix='rj-idle-',dir='/tmp') as directory:
        path=Path(directory)/'runtime.sock';provider=IdleProvider();server=RuntimeServer(path,provider)
        server.start();thread=server.run_in_thread()
        provider.status='unloaded'
        thread.join(timeout=2)
        assert not thread.is_alive()
        assert provider.closed and not path.exists()

def test_failed_provider_start_releases_listener_and_socket():
    class Failed(IdleProvider):
        def start(self):raise RuntimeError('fixture-start-failure')
    with tempfile.TemporaryDirectory(prefix='rj-start-',dir='/tmp') as directory:
        path=Path(directory)/'runtime.sock';server=RuntimeServer(path,Failed())
        with pytest.raises(RuntimeError):server.start()
        assert not server.is_running and not path.exists()
        # A valid replacement can bind immediately, without unlinking an active process.
        replacement=RuntimeServer(path,IdleProvider());replacement.start();replacement.stop()
        assert not path.exists()
