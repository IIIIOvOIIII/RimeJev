"""Exercise the public runner in disposable repos with harmless Python commands."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import pytest
import yaml


RUNNER = Path(__file__).resolve().parents[1] / "scripts/quality_gate.py"
REQUIRED = {
    "local": ["backend", "frontend", "lint", "build"],
    "deploy-preflight": ["backend", "frontend", "lint", "build", "deploy_contracts"],
    "post-deploy-readonly": ["e2e_prod_smoke"],
}


def command(code: str, *, timeout: float = 5, side_effect: str = "local") -> dict:
    return {"argv": [sys.executable, "-c", code], "timeout_seconds": timeout, "side_effect": side_effect}


def report_writer(xml: str) -> str:
    return (
        "from pathlib import Path; "
        "p=Path('artifacts/coverage/backend.xml'); p.parent.mkdir(parents=True, exist_ok=True); "
        f"p.write_text({xml!r}); print('coverage written', flush=True)"
    )


@pytest.fixture
def repo(tmp_path: Path) -> tuple[Path, dict]:
    root = tmp_path / "public checkout with spaces"
    root.mkdir()
    commands = {}
    for name in (*REQUIRED["deploy-preflight"], "e2e_prod_smoke"):
        code = f"from pathlib import Path; Path({name!r}).write_text('ran'); print({name!r}, flush=True)"
        if name == "backend":
            code += "; " + report_writer('<coverage line-rate="0.85" branch-rate="0.4" lines-valid="100"/>')
        commands[name] = command(code, side_effect="production-readonly" if name == "e2e_prod_smoke" else "local")
    return root, {
        "schema_version": "2.0.0", "project": "temporary-public-gate",
        "artifacts": {"dir": "artifacts/quality-gate"},
        "coverage": {"backend": {
            "format": "cobertura", "path": "artifacts/coverage/backend.xml", "minimum": {"lines": 85},
        }},
        "commands": commands, "required": {gate: list(names) for gate, names in REQUIRED.items()},
    }


def run_gate(repo: tuple[Path, dict], gate: str = "local") -> tuple[subprocess.CompletedProcess, dict]:
    root, config = repo
    (root / "quality-gate.yml").write_text(yaml.safe_dump(config))
    result = subprocess.run(
        [sys.executable, str(RUNNER), "--repo-root", str(root), "--gate", gate],
        cwd=root, capture_output=True, text=True, timeout=15, shell=False,
    )
    summaries = list((root / config["artifacts"]["dir"]).glob(f"*-{gate}/summary.json"))
    assert len(summaries) == 1, (result.stdout, result.stderr)
    return result, json.loads(summaries[0].read_text())


@pytest.mark.parametrize("gate", REQUIRED)
def test_gate_runs_only_its_required_commands_and_reports_coverage(repo, gate):
    root, config = repo
    result, summary = run_gate(repo, gate)
    assert result.returncode == 0, result.stderr
    assert summary["status"] == "passed"
    assert summary["gate"] == gate
    assert summary["source_sha"] is None
    assert [check["name"] for check in summary["checks"]] == REQUIRED[gate]
    for check in summary["checks"]:
        assert check["argv"] == config["commands"][check["name"]]["argv"]
        assert check["returncode"] == 0
        assert check["status"] == "passed"
        assert check["name"] in (root / check["log"]).read_text()
    assert {name for name in config["commands"] if (root / name).exists()} == set(REQUIRED[gate])
    if gate == "post-deploy-readonly":
        assert summary["coverage"] == {}
        assert not (root / "artifacts/coverage/backend.xml").exists()
    else:
        assert summary["coverage"]["backend"]["lines"] == 85
        assert summary["coverage"]["backend"]["branches"] == 40
        assert summary["coverage"]["backend"]["status"] == "passed"


def test_failed_command_fails_gate_even_when_coverage_passes(repo):
    root, config = repo
    config["commands"]["backend"]["argv"][-1] += "; import sys; print('failure detail', file=sys.stderr); sys.exit(7)"
    result, summary = run_gate(repo)
    assert result.returncode != 0
    assert summary["status"] == "failed"
    assert summary["coverage"]["backend"]["status"] == "passed"
    failed = summary["checks"][0]
    assert failed["returncode"] == 7
    assert failed["status"] == "failed"
    assert "failure detail" in (root / failed["log"]).read_text()
    assert [check["name"] for check in summary["checks"]] == REQUIRED["local"]
    assert (root / "build").exists()


def test_argv_is_preserved_without_shell_expansion(repo):
    root, config = repo
    literal = "$(touch shell_was_used); * $HOME ' spaces"
    config["commands"]["lint"]["argv"] = [sys.executable, "-c", "import sys; print(repr(sys.argv[1:]))", literal, ""]
    result, summary = run_gate(repo)
    assert result.returncode == 0
    check = next(check for check in summary["checks"] if check["name"] == "lint")
    assert (root / check["log"]).read_text().strip() == repr([literal, ""])
    assert not (root / "shell_was_used").exists()


def test_missing_executable_fails_with_log_and_summary(repo):
    root, config = repo
    config["commands"]["lint"]["argv"] = ["./missing-executable"]
    result, summary = run_gate(repo)
    assert result.returncode != 0
    check = next(check for check in summary["checks"] if check["name"] == "lint")
    assert check["status"] == "failed"
    assert check["returncode"] is None
    assert "missing-executable" in (root / check["log"]).read_text()


@pytest.mark.skipif(os.name != "posix", reason="process-group cleanup is a macOS/POSIX contract")
def test_timeout_fails_and_stops_descendant_process(repo):
    root, config = repo
    child_code = "import time; from pathlib import Path; time.sleep(2); Path('orphan-finished').write_text('bad')"
    config["commands"]["lint"] = command(
        "import subprocess, sys, time; "
        f"subprocess.Popen([sys.executable, '-c', {child_code!r}]); "
        "print('child launched', flush=True); time.sleep(30)", timeout=1,
    )
    started = time.monotonic()
    result, summary = run_gate(repo)
    assert time.monotonic() - started < 10
    assert result.returncode != 0
    check = next(check for check in summary["checks"] if check["name"] == "lint")
    assert check["status"] == "failed"
    assert check["timed_out"] is True
    assert check["returncode"] != 0
    log = (root / check["log"]).read_text()
    assert "child launched" in log
    assert "timed out after 1 seconds" in log
    time.sleep(2)
    assert not (root / "orphan-finished").exists()
    assert (root / "build").exists()


@pytest.mark.parametrize("rate,passes", [("0.84999", False), ("0.85", True), ("1", True)])
def test_coverage_minimum_is_enforced_without_rounding(repo, rate, passes):
    _, config = repo
    config["commands"]["backend"] = command(report_writer(f'<coverage line-rate="{rate}" lines-valid="100"/>'))
    result, summary = run_gate(repo)
    assert (result.returncode == 0) is passes
    assert all(check["status"] == "passed" for check in summary["checks"])
    assert summary["coverage"]["backend"]["status"] == ("passed" if passes else "failed")
    assert summary["coverage"]["backend"]["lines"] == float(rate) * 100


@pytest.mark.parametrize("xml", [
    '<coverage line-rate="NaN"/>', '<coverage line-rate="inf"/>',
    '<coverage line-rate="1.01"/>', '<coverage line-rate="-0.1"/>',
    '<coverage/>', '<coverage line-rate="1" lines-valid="0"/>',
    '<not-coverage line-rate="1"/>', 'invalid xml',
])
def test_invalid_coverage_cannot_pass(repo, xml):
    _, config = repo
    config["commands"]["backend"] = command(report_writer(xml))
    result, summary = run_gate(repo)
    assert result.returncode != 0
    assert summary["coverage"]["backend"]["status"] == "failed"
    assert "invalid or missing" in summary["coverage"]["backend"]["error"]


def test_stale_passing_coverage_cannot_hide_missing_report(repo):
    root, config = repo
    report = root / "artifacts/coverage/backend.xml"
    report.parent.mkdir(parents=True)
    report.write_text('<coverage line-rate="1"/>')
    config["commands"]["backend"] = command("print('no coverage generated')")
    result, summary = run_gate(repo)
    assert result.returncode != 0
    assert not report.exists()
    assert summary["coverage"]["backend"]["status"] == "failed"
    assert "missing coverage report" in summary["coverage"]["backend"]["error"]


@pytest.mark.parametrize("field,value", [
    ("argv", "echo shell string"), ("argv", []), ("argv", [sys.executable, 1]),
    ("timeout_seconds", 0), ("timeout_seconds", -1), ("timeout_seconds", 3601),
    ("timeout_seconds", float("inf")), ("timeout_seconds", True),
    ("side_effect", "production-write"),
])
def test_invalid_command_config_fails_before_running_any_check(repo, field, value):
    root, config = repo
    config["commands"]["build"][field] = value
    result, summary = run_gate(repo)
    assert result.returncode != 0
    assert summary["status"] == "failed"
    assert summary["checks"] == []
    assert "error" in summary
    assert not (root / "backend").exists()


def test_readonly_gate_rejects_a_local_or_mutating_command(repo):
    _, config = repo
    config["commands"]["e2e_prod_smoke"]["side_effect"] = "local"
    result, summary = run_gate(repo, "post-deploy-readonly")
    assert result.returncode != 0
    assert summary["checks"] == []
    assert "production-readonly" in summary["error"]


def test_empty_required_checks_cannot_pass(repo):
    _, config = repo
    config["required"]["local"] = []
    result, summary = run_gate(repo)
    assert result.returncode != 0
    assert summary["checks"] == []


def test_summary_uses_own_repository_commit_and_default_cli_paths(repo):
    root, config = repo
    for args in (("init", "-q"), ("-c", "user.name=Quality Gate Test", "-c", "user.email=test@example.invalid",
                                  "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "temporary test")):
        subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, timeout=10)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True, timeout=10).strip()
    (root / "scripts").mkdir()
    shutil.copyfile(RUNNER, root / "scripts/quality_gate.py")
    (root / "quality-gate.yml").write_text(yaml.safe_dump(config))
    result = subprocess.run([sys.executable, "scripts/quality_gate.py", "--gate", "local"],
                            cwd=root, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    summaries = list((root / "artifacts/quality-gate").glob("*-local/summary.json"))
    assert len(summaries) == 1
    assert json.loads(summaries[0].read_text())["source_sha"] == sha


def test_uninitialized_child_directory_does_not_report_parent_sha(repo):
    root, _ = repo
    for args in (("init", "-q"), ("-c", "user.name=Quality Gate Test", "-c", "user.email=test@example.invalid",
                                  "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "temporary parent")):
        subprocess.run(["git", *args], cwd=root.parent, check=True, capture_output=True, timeout=10)
    result, summary = run_gate(repo)
    assert result.returncode == 0
    assert summary["source_sha"] is None
