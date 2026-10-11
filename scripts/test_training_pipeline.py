#!/usr/bin/env python3
"""Bounded, offline integration of actual Swift capture/storage and Python export.

No source stubs, GUI, user settings, Keychain credentials or real input are used.
Compile budget: 90 seconds. Three independent pipeline cases: 30 seconds each.
Only a summary is printed; temporary sources, ciphertext and exports are removed.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


class Failure(Exception):
    """Fixed test descriptions, never source records or subprocess output."""


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise Failure(reason)


def read_rows(output: Path, name: str) -> list[dict]:
    return [json.loads(line) for split in ("train", "dev", "test")
            for line in (output / name / f"{split}.jsonl").read_text(encoding="utf-8").splitlines()]


def check_no_models(value: object) -> None:
    forbidden = {"models", "model_windows", "environment", "probabilities", "choice_id",
                 "model_coverage", "providers", "applied", "elapsed_ms", "budget_ms"}
    if isinstance(value, dict):
        require(not (forbidden & value.keys()), "model metadata leaked into training")
        for child in value.values():
            check_no_models(child)
    elif isinstance(value, list):
        for child in value:
            check_no_models(child)


def run_case(root: Path, work: Path, executable: Path, python: Path,
             environment: dict[str, str], name: str, *, corrected: bool = False,
             include_corrected: bool = False) -> tuple[int, int]:
    case = work / name
    case.mkdir(mode=0o700)
    output = case / "export"
    require(not output.exists(), "export destination must be new")
    producer = consumer = None
    try:
        producer = subprocess.Popen(
            [str(executable), str(case), "corrected" if corrected else "human"],
            cwd=work, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        arguments = [str(python), "-s", str(root / "scripts/export_training.py"),
                     "--input", "-", "--output", str(output)]
        if include_corrected:
            arguments.append("--include-corrected")
        consumer = subprocess.Popen(arguments, cwd=work, env=environment,
                                    stdin=producer.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        producer.stdout.close()
        exported_stdout, _ = consumer.communicate(timeout=25)
        producer.wait(timeout=5)
        native_summary = producer.stderr.read()
        if producer.returncode != 0:
            reason = "actual Swift capture/storage failed"
            if (native_summary.startswith(b"FAIL: ") and native_summary.isascii()
                    and len(native_summary) < 160 and b"\n" not in native_summary):
                reason = native_summary[6:].decode("ascii")
            raise Failure(f"{name}: {reason}")
        require(consumer.returncode == 0, f"{name}: actual exporter failed")
    finally:
        for child in (consumer, producer):
            if child is not None:
                if child.poll() is None:
                    child.kill()
                child.wait(timeout=5)
                for stream in (child.stdout, child.stderr):
                    if stream is not None:
                        stream.close()

    native = json.loads(native_summary)
    expected_records = 2 if corrected else 1
    expected_examples = 0 if corrected and not include_corrected else 1
    require(native["records"] == expected_records and native["selections"] == 1
            and native["corrections"] == int(corrected), f"{name}: collector event counts differ")
    require(native["state"] == "off" and native["synthetic_key_only"] and native["off_main_read"],
            f"{name}: isolated storage contract failed")
    require(native["encrypted_files"] > 0, f"{name}: ciphertext missing")
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    require(json.loads(exported_stdout) == manifest, f"{name}: exporter summary differs from manifest")
    require(manifest["exported_examples"] == expected_examples, f"{name}: exported example count differs")
    require(manifest["quality"]["selection_events"] == 1
            and manifest["quality"]["correction_events"] == int(corrected), f"{name}: events lost across pipe")
    require(manifest["quality"]["excluded"].get("corrected", 0) == int(corrected and not include_corrected),
            f"{name}: correction exclusion was not exercised")
    require(manifest["model_outputs_in_training"] is False, f"{name}: model output policy differs")
    records, sft = read_rows(output, "records"), read_rows(output, "sft")
    require(len(records) == len(sft) == expected_examples, f"{name}: records/sft row count differs")
    if expected_examples:
        record, messages = records[0], sft[0]["messages"]
        require(record["state"]["context"] == "汽车" and record["state"]["pinyin"] == "youxiang",
                f"{name}: context/pinyin changed")
        selected = [option for option in record["options"] if option["label"] == record["answer"]]
        require(len(selected) == 1 and selected[0]["description"] == "油箱"
                and selected[0]["key"] == record["answer_key"] == "c1", f"{name}: human digit2 label lost")
        require({option["description"] for option in record["options"] if option["key"] in {"c0", "c1"}}
                == {"邮箱", "油箱"}, f"{name}: native candidates changed")
        require(record["provenance"]["record_ids"] == [native["selection_id"]]
                and record["provenance"]["corrected"] == corrected, f"{name}: actual selection provenance lost")
        require([message["role"] for message in messages] == ["system", "user", "assistant"],
                f"{name}: SFT roles differ")
        require(messages[-1]["content"] == record["answer"], f"{name}: SFT human label differs")
        require(json.loads(messages[1]["content"]) == {key: record[key] for key in ("state", "question", "options")},
                f"{name}: SFT task differs from records")
    check_no_models(records)
    check_no_models(sft)
    for path in output.rglob("*"):
        if path.is_file():
            require(b"SYNTHETIC_MODEL_ONLY_DO_NOT_TRAIN" not in path.read_bytes(), f"{name}: model sentinel leaked")
    require(not (output / "instruction").exists(), f"{name}: tokenizer was unexpectedly used")
    return expected_records, expected_examples


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    compiler = shutil.which("swiftc")
    python = root / ".venv/bin/python"
    require(sys.platform == "darwin" and compiler is not None, "macOS Swift compiler required")
    require(python.is_file(), "existing project Python environment required")
    with tempfile.TemporaryDirectory(prefix="jev-training-pipeline-") as temporary:
        work = Path(temporary).resolve()
        sources = []
        for relative in ("JevTrainingSettings.swift", "JevCore.swift", "JevCandidatePlan.swift", "JevLineContext.swift",
                         "JevTrainingCapture.swift", "JevTrainingStore.swift", "tests/JevTrainingPipelineTests.swift"):
            target = work / Path(relative).name
            target.write_bytes((root / "native" / relative).read_bytes())
            sources.append(str(target))
        executable = work / "JevTrainingPipelineTests"
        compiled = subprocess.run(
            [compiler, "-parse-as-library", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macosx13.0",
             "-module-cache-path", str(work / "module-cache"), *sources,
             "-framework", "Foundation", "-framework", "CryptoKit", "-framework", "Security", "-o", str(executable)],
            cwd=work, capture_output=True, timeout=90,
        )
        require(compiled.returncode == 0, "actual Swift components did not compile")
        guard = work / "offline-guard"
        guard.mkdir()
        # urllib3 probes local IPv6 at import; block that bind too, without treating it as outbound traffic.
        (guard / "sitecustomize.py").write_text(
            "from pathlib import Path\nimport sys\n"
            "root = Path(__file__).parent\n(root / 'active').touch()\n"
            "def deny_network(event, args):\n"
            "    if event == 'socket.bind' and args[1] == ('::1', 0):\n"
            "        raise PermissionError('Local IPv6 probe disabled in pipeline test')\n"
            "    if event in {'socket.connect', 'socket.bind', 'socket.getaddrinfo',\n"
            "                 'socket.gethostbyname', 'socket.gethostbyaddr', 'socket.sendto', 'socket.sendmsg'}:\n"
            "        (root / 'attempted').write_text(event)\n"
            "        raise PermissionError('Network disabled in synthetic pipeline test')\n"
            "sys.addaudithook(deny_network)\n", encoding="utf-8",
        )
        environment = dict(os.environ, PYTHONPATH=str(guard), PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1",
                           HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1",
                           HF_HUB_DISABLE_TELEMETRY="1")
        results = [run_case(root, work, executable, python, environment, "human"),
                   run_case(root, work, executable, python, environment, "corrected", corrected=True),
                   run_case(root, work, executable, python, environment, "include-corrected",
                            corrected=True, include_corrected=True)]
        require((guard / "active").exists(), "offline guard did not load")
        require(not (guard / "attempted").exists(), "network attempted while running exporter")
    require(not work.exists(), "temporary fixtures were not removed")
    captured = "/".join(str(records) for records, _ in results)
    exported = "/".join(str(examples) for _, examples in results)
    print(f"PASS training pipeline: capture_records={captured}; exported_examples={exported}; "
          "human=油箱 (digit2), model=c0/邮箱; correction exclusion and opt-in verified; "
          "ciphertext has no plaintext; no model leakage, Keychain, GUI, user settings or network; temporary fixtures removed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Failure as error:
        print(f"FAIL training pipeline: {error}")
        raise SystemExit(1) from None
    except subprocess.TimeoutExpired:
        print("FAIL training pipeline: bounded compile or execution timeout")
        raise SystemExit(1) from None
    except (OSError, ValueError, KeyError, TypeError):
        print("FAIL training pipeline: fixture, process or output validation failed")
        raise SystemExit(1) from None
