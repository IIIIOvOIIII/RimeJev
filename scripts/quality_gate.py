#!/usr/bin/env python3
"""Run quality-gate.yml locally; save logs and summary.json under <time>-<gate>."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import xml.etree.ElementTree as ET

import yaml


GATES = ("local", "deploy-preflight", "post-deploy-readonly")
MAX_TIMEOUT_SECONDS = 3600


def repo_path(root: Path, value: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError("expected a nonempty repository-relative path")
    path = (root / value).resolve()
    if Path(value).is_absolute() or not path.is_relative_to(root) or path == root:
        raise ValueError(f"path must stay inside the repository: {value}")
    return path


def number(value: object, label: str, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a number")
    if not math.isfinite(value) or not 0 <= value <= maximum:
        raise ValueError(f"{label} must be between 0 and {maximum}")
    return float(value)


def load_config(root: Path, path: Path, gate: str) -> tuple[dict, list[str]]:
    config = yaml.safe_load(path.read_text())
    if not isinstance(config, dict):
        raise ValueError("quality-gate config must be a mapping")
    required = config.get("required", {})
    commands = config.get("commands", {})
    if not isinstance(required, dict) or not isinstance(commands, dict):
        raise ValueError("required and commands must be mappings")
    names = required.get(gate)
    if not isinstance(names, list) or not names:
        raise ValueError(f"required.{gate} must be a nonempty list")
    if any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name) for name in names):
        raise ValueError("required check names must be safe filename components")
    if len(set(names)) != len(names):
        raise ValueError("required check names must be unique")
    expected_effect = "production-readonly" if gate == "post-deploy-readonly" else "local"
    for name in names:
        command = commands.get(name)
        if not isinstance(command, dict):
            raise ValueError(f"missing command: {name}")
        argv = command.get("argv")
        if not isinstance(argv, list) or not argv or any(not isinstance(arg, str) or "\0" in arg for arg in argv) or not argv[0]:
            raise ValueError(f"{name}.argv must be a nonempty argument list")
        timeout = number(command.get("timeout_seconds"), f"{name}.timeout_seconds", MAX_TIMEOUT_SECONDS)
        if timeout == 0:
            raise ValueError(f"{name}.timeout_seconds must be positive")
        if command.get("side_effect") != expected_effect:
            raise ValueError(f"{name}.side_effect must be {expected_effect} for {gate}")
    artifacts = config.get("artifacts", {})
    if not isinstance(artifacts, dict):
        raise ValueError("artifacts must be a mapping")
    repo_path(root, artifacts.get("dir", "artifacts/quality-gate"))
    coverage = config.get("coverage", {})
    if not isinstance(coverage, dict):
        raise ValueError("coverage must be a mapping")
    for name, spec in coverage.items():
        if name not in names:
            continue
        if not isinstance(spec, dict) or spec.get("format") != "cobertura":
            raise ValueError(f"coverage.{name} must use cobertura")
        repo_path(root, spec.get("path"))
        minimum = spec.get("minimum")
        if not isinstance(minimum, dict) or not minimum or minimum.keys() - {"lines", "branches"}:
            raise ValueError(f"coverage.{name}.minimum must specify lines and/or branches")
        for metric, value in minimum.items():
            number(value, f"coverage.{name}.minimum.{metric}", 100)
    return config, names


def source_sha(root: Path) -> str | None:
    """An uninitialized release directory must not inherit a parent repo SHA."""
    try:
        def git(*args: str) -> str:
            return subprocess.run(
                ["git", "-C", str(root), *args], check=True, capture_output=True,
                text=True, timeout=10, shell=False,
            ).stdout.strip()
        if Path(git("rev-parse", "--show-toplevel")).resolve() != root:
            return None
        return git("rev-parse", "--verify", "HEAD")
    except (OSError, subprocess.SubprocessError):
        return None


def run_check(root: Path, run_dir: Path, name: str, command: dict) -> dict:
    log_path = run_dir / f"{name}.log"
    result = {
        "name": name, "argv": command["argv"], "status": "failed",
        "returncode": None, "timed_out": False,
        "timeout_seconds": command["timeout_seconds"],
        "log": str(log_path.relative_to(root)),
    }
    started = time.monotonic()
    with log_path.open("w") as log:
        try:
            process = subprocess.Popen(
                command["argv"], cwd=root, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, shell=False,
                start_new_session=(os.name == "posix"),
            )
            try:
                process.wait(timeout=command["timeout_seconds"])
            except subprocess.TimeoutExpired:
                result["timed_out"] = True
                result["error"] = f"timed out after {command['timeout_seconds']} seconds"
                # Build/test scripts spawn children; end the entire timed-out group.
                if os.name == "posix":
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                else:
                    process.kill()
                process.wait(timeout=5)
                log.write(f"\nquality_gate: {result['error']}\n")
            result["returncode"] = process.returncode
            if process.returncode == 0 and not result["timed_out"]:
                result["status"] = "passed"
        except (OSError, subprocess.SubprocessError) as exc:
            result["error"] = str(exc)
            log.write(f"\nquality_gate: {exc}\n")
    result["duration_seconds"] = round(time.monotonic() - started, 3)
    return result


def check_coverage(root: Path, spec: dict) -> dict:
    result = {"status": "failed", "path": spec["path"], "minimum": spec["minimum"]}
    try:
        document = ET.parse(repo_path(root, spec["path"])).getroot()
        if document.tag != "coverage":
            raise ValueError("expected a Cobertura coverage document")
        for metric, attribute in (("lines", "line-rate"), ("branches", "branch-rate")):
            if attribute not in document.attrib and metric not in spec["minimum"]:
                continue
            value = float(document.attrib[attribute])
            result[metric] = number(value, attribute, 1) * 100
        if "lines-valid" in document.attrib and float(document.attrib["lines-valid"]) <= 0:
            raise ValueError("coverage report contains no measured lines")
        below = [name for name, minimum in spec["minimum"].items() if result[name] < minimum]
        if below:
            result["error"] = "coverage below minimum: " + ", ".join(below)
        else:
            result["status"] = "passed"
    except (OSError, ValueError, KeyError, ET.ParseError) as exc:
        result["error"] = f"invalid or missing coverage report: {exc}"
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", choices=GATES, default="local")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--config", type=Path, default=Path("quality-gate.yml"))
    args = parser.parse_args(argv)
    root = args.repo_root.resolve()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    run_name = f"{stamp}-{args.gate}"
    run_dir = root / "artifacts/quality-gate" / run_name
    summary = {
        "status": "failed", "gate": args.gate, "source_sha": source_sha(root),
        "checks": [], "coverage": {}, "started_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        config, names = load_config(root, root / args.config, args.gate)
        run_dir = repo_path(root, config.get("artifacts", {}).get("dir", "artifacts/quality-gate")) / run_name
        run_dir.mkdir(parents=True, exist_ok=False)
        coverage = {name: spec for name, spec in config.get("coverage", {}).items() if name in names}
        # Only reports generated by this run may satisfy a coverage minimum.
        for spec in coverage.values():
            report = repo_path(root, spec["path"])
            report.parent.mkdir(parents=True, exist_ok=True)
            report.unlink(missing_ok=True)
        for name in names:
            result = run_check(root, run_dir, name, config["commands"][name])
            summary["checks"].append(result)
            print(f"{name}: {result['status']}", flush=True)
        summary["coverage"] = {name: check_coverage(root, spec) for name, spec in coverage.items()}
        if all(check["status"] == "passed" for check in summary["checks"]) and all(
            result["status"] == "passed" for result in summary["coverage"].values()
        ):
            summary["status"] = "passed"
    except (OSError, ValueError, yaml.YAMLError) as exc:
        summary["error"] = str(exc)
    summary["finished_at"] = datetime.now(timezone.utc).isoformat()
    run_dir.mkdir(parents=True, exist_ok=True)
    summary_path = run_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, allow_nan=False) + "\n")
    print(f"{args.gate}: {summary['status']} — {summary_path}", flush=True)
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
