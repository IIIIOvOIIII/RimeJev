"""Generated synthetic fixtures only; no live input, models, credentials or network."""

from __future__ import annotations

from copy import deepcopy
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import types

import pytest

from rime_jev import training_export as exporter


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError("Training export must never access the network")

    monkeypatch.setattr(socket, "create_connection", forbidden)
    monkeypatch.setattr(socket.socket, "connect", forbidden)
    monkeypatch.setattr(socket.socket, "connect_ex", forbidden)
    monkeypatch.setattr(socket, "getaddrinfo", forbidden)


def selection(index=0, *, context="合成的前文", pinyin="ceshi", target=0, count=3):
    baseline = [{"id": f"native-{i}", "key": str(i), "text": f"合成候选{i}", "rank": i}
                for i in range(count)]
    return {
        "schema_version": 1, "event_type": "selection", "id": f"record-{index}",
        "session_id": "synthetic-session", "composition_id": f"composition-{index}",
        "segment_index": 0, "created_at": "2026-10-11T04:05:06Z", "app_id": "synthetic.app",
        "environment": {"model_mode": "MODEL_SECRET"},
        "input": {"raw": pinyin, "pinyin": pinyin, "display_code": pinyin,
                  "abbreviated": False, "confirmed_prefix": ""},
        "context": {"text": context, "source": "synthetic", "length": len(context or ""), "truncated": False},
        "baseline": baseline,
        "display": {"page": 0, "items": [{"id": c["id"], "text": c["text"], "rank": c["rank"]} for c in baseline],
                    "model_annotation": "MODEL_SECRET"},
        "model_windows": {"synthetic": ["MODEL_SECRET"]},
        "models": [{"provider": "MODEL_SECRET", "model": "MODEL_SECRET", "status": "timeout",
                    "choice_id": "none", "probabilities": {"none": 1.0}, "text": "MODEL_SECRET"}],
        "selection": {"candidate_id": baseline[target]["id"], "text": baseline[target]["text"],
                      "method": "space", "coverage": "covered", "status": "committed", "host_ack": "observed"},
        "correction": "unknown",
    }


def correction(record_id):
    return {"schema_version": 1, "event_type": "correction", "id": f"correction-{record_id}",
            "record_id": record_id, "created_at": "2026-10-13T00:00:00Z", "observation": "edited_after_commit"}


def stream(rows):
    return io.BytesIO(("\n".join(json.dumps(row, ensure_ascii=False) for row in rows) + "\n").encode())


def export(tmp_path, rows, **kwargs):
    output = tmp_path / "dataset"
    manifest = exporter.export_training(stream(rows), output, **kwargs)
    return output, manifest


def read_rows(output, name="records"):
    return [(split, json.loads(line)) for split in exporter.SPLITS
            for line in (output / name / f"{split}.jsonl").read_text().splitlines()]


def files(output):
    return {str(path.relative_to(output)): path.read_bytes() for path in output.rglob("*") if path.is_file()}


def task_from_record(record):
    return {key: record[key] for key in ("state", "question", "options")}


def selected_option(record):
    matches = [option for option in record["options"] if option["label"] == record["answer"]]
    assert len(matches) == 1
    assert matches[0]["key"] == record["answer_key"]
    return matches[0]


def test_basic_records_sft_and_private_manifest(tmp_path):
    row = selection()
    output, manifest = export(tmp_path, [row])
    assert manifest["exported_examples"] == 1
    assert manifest["formats"]["instruction"] == {
        "available": False, "reason": "local_tokenizer_required", "files": [],
    }
    assert not (output / "instruction").exists()
    split, record = read_rows(output)[0]
    sft_split, sft = read_rows(output, "sft")[0]
    assert split == sft_split
    assert record["provenance"]["record_ids"] == [row["id"]]
    assert "task" not in record
    assert record["source"] == "rime_jev" and record["split"] == split and record["kind"] == "choice"
    assert record["token_count"] is None
    assert manifest["limits"]["max_tokens"] == 2048
    assert manifest["tokenization"]["max_tokens_enforced"] is False
    assert "token_limit_unchecked_without_local_tokenizer" in manifest["warnings"]
    task = task_from_record(record)
    assert set(task) == {"state", "question", "options"}
    assert task["state"] == {"context": row["context"]["text"], **row["input"]}
    assert selected_option(record)["description"] == row["selection"]["text"]
    assert record["answer_key"] == row["selection"]["candidate_id"]
    assert [option["label"] for option in task["options"]] == ["A", "B", "C", "D"]
    assert all(set(option) == {"label", "key", "description"} for option in task["options"])
    assert sft["messages"][0] == {"role": "system", "content": exporter.SYSTEM}
    assert json.loads(sft["messages"][1]["content"]) == task
    assert sft["messages"][1]["content"] == json.dumps(task, ensure_ascii=False)
    assert sft["messages"][2] == {"role": "assistant", "content": record["answer"]}
    assert all(b"MODEL_SECRET" not in data for data in files(output).values())
    assert json.loads((output / "manifest.json").read_text()) == manifest
    summary = json.dumps(manifest, ensure_ascii=False)
    for private in (row["context"]["text"], row["app_id"], row["selection"]["text"], row["input"]["raw"]):
        assert private not in summary
    assert manifest["quality"]["input_modes"] == {"full": 1}
    assert manifest["quality"]["selection_methods"] == {"space": 1}
    assert manifest["quality"]["coverage"] == {"covered": 1}
    assert len(manifest["split_isolation"]["empty_splits"]) == 2
    assert not manifest["split_isolation"]["all_splits_present"]
    for path in [output, *output.rglob("*")]:
        assert path.stat().st_mode & 0o777 == (0o700 if path.is_dir() else 0o600)


@pytest.mark.parametrize(("change", "reason"), [
    ({"selection": {"status": "cancelled"}}, "not_committed"),
    ({"selection": {"status": "partial"}}, "not_committed"),
    ({"selection": {"status": "raw"}}, "not_committed"),
    ({"selection": {"status": "timeout"}}, "not_committed"),
    ({"selection": {"coverage": "ambiguous"}}, "coverage_ambiguous"),
    ({"selection": {"coverage": "missing"}}, "coverage_missing"),
    ({"selection": {"candidate_id": None}}, "coverage_missing"),
    ({"selection": {"candidate_id": "none", "text": "none"}}, "coverage_missing"),
    ({"selection": {"text": "incorrect text"}}, "coverage_missing"),
    ({"context": {"text": None}}, "context_unavailable"),
    ({"input": {"abbreviated": "false"}}, "invalid_input"),
    ({"input": {"pinyin": ""}}, "invalid_input"),
    ({"segment_index": -1}, "invalid_metadata"),
    ({"created_at": "private invalid timestamp"}, "invalid_timestamp"),
])
def test_ineligible_rows_never_become_none_labels(tmp_path, change, reason):
    row = selection()
    for key, value in change.items():
        if isinstance(value, dict):
            row[key].update(value)
        else:
            row[key] = value
    output, manifest = export(tmp_path, [row])
    assert manifest["exported_examples"] == 0
    assert manifest["quality"]["excluded"][reason] == 1
    assert manifest["none_labels"] == 0
    assert not read_rows(output)


@pytest.mark.parametrize("variant", ["same_id", "same_text", "repeated", "invalid_rank", "singleton"])
def test_unique_identity_and_multiple_candidates_required(tmp_path, variant):
    row = selection()
    if variant == "same_id":
        row["baseline"][1]["id"] = row["baseline"][0]["id"]
    elif variant == "same_text":
        row["baseline"][1]["text"] = row["baseline"][0]["text"]
    elif variant == "repeated":
        row["baseline"].append(deepcopy(row["baseline"][0]))
    elif variant == "invalid_rank":
        row["baseline"][0]["rank"] = "private text"
    else:
        row["baseline"] = row["baseline"][:1]
    _, manifest = export(tmp_path, [row])
    expected = {"invalid_rank": "invalid_candidates", "singleton": "insufficient_candidates"}.get(variant, "coverage_ambiguous")
    assert manifest["quality"]["excluded"][expected] == 1


def test_empty_context_abbreviated_and_unknown_ack_are_valid(tmp_path):
    row = selection(context="", pinyin="cs")
    row["input"]["abbreviated"] = True
    row["selection"].update(host_ack="unknown", method="unknown-private-method")
    _, manifest = export(tmp_path, [row])
    assert manifest["exported_examples"] == 1
    assert manifest["quality"]["input_modes"] == {"abbreviated": 1}
    assert manifest["quality"]["host_ack"] == {"unknown": 1}
    assert manifest["quality"]["selection_methods"] == {"other": 1}
    assert "unknown-private-method" not in json.dumps(manifest)


@pytest.mark.parametrize("before", [False, True])
@pytest.mark.parametrize("include", [False, True])
def test_followup_corrections_ignore_filters_and_input_order(tmp_path, before, include):
    row = selection()
    followup = correction(row["id"])
    rows = [followup, row] if before else [row, followup]
    output, manifest = export(tmp_path, rows, include_corrected=include, apps=["synthetic.app"],
                              from_date="2026-10-11", to_date="2026-10-11")
    assert manifest["exported_examples"] == int(include)
    assert manifest["quality"]["corrected_eligible_records"] == 1
    assert manifest["quality"]["correction_events"] == 1
    if include:
        record = read_rows(output)[0][1]
        assert record["provenance"]["corrected"] is True
        assert selected_option(record)["description"] == row["selection"]["text"]
    else:
        assert manifest["quality"]["excluded"]["corrected"] == 1


def test_inline_correction_and_unmatched_followup(tmp_path):
    row = selection()
    row["correction"] = "edited_after_commit"
    _, manifest = export(tmp_path, [row, correction("not-present")])
    assert manifest["quality"]["excluded"]["corrected"] == 1


@pytest.mark.parametrize("change", [{"id": None}, {"record_id": ""}, {"created_at": "invalid"},
                                    {"observation": "unknown"}])
def test_malformed_followup_cannot_correct_a_selection(tmp_path, change):
    row = selection()
    followup = {**correction(row["id"]), **change}
    _, manifest = export(tmp_path, [row, followup])
    assert manifest["exported_examples"] == 1
    assert manifest["quality"]["excluded"]["invalid_correction"] == 1
    assert manifest["quality"]["corrected_eligible_records"] == 0


def test_exclude_text_ignores_non_text_metadata_and_model_outputs(tmp_path):
    _, manifest = export(tmp_path, [selection()], exclude_text=["committed", "space", "MODEL_SECRET", "synthetic"])
    assert manifest["exported_examples"] == 1


def test_filters_utc_days_apps_and_normalized_text(tmp_path):
    rows = [selection(i, context=f"synthetic context {i}") for i in range(7)]
    rows[0]["created_at"] = "2026-10-11T23:59:59.999999Z"
    rows[1]["created_at"] = "2026-10-12T08:00:00+08:00"
    rows[2]["app_id"] = "other.app"
    rows[3]["input"]["confirmed_prefix"] = "ＦＯＲＢＩＤＤＥＮ  text"
    rows[4]["baseline"][2]["text"] = "Blocked Word"
    rows[5]["app_id"] = "also.allowed"
    rows[5]["created_at"] = "2026-10-11T08:00:00+08:00"
    rows[6]["created_at"] = "2026-10-10T23:59:59Z"
    output, manifest = export(tmp_path, rows, apps=["synthetic.app", "also.allowed"],
                              from_date="2026-10-11", to_date="2026-10-11",
                              exclude_text=["forbidden text", "blocked word"])
    assert {row["provenance"]["record_ids"][0] for _, row in read_rows(output)} == {"record-0", "record-5"}
    assert manifest["quality"]["excluded"] == {"app_filter": 1, "date_filter": 2, "text_filter": 2, "duplicate_example": 0}
    assert "forbidden" not in json.dumps(manifest)


@pytest.mark.parametrize("kwargs", [{"from_date": "not a date"}, {"to_date": "2026-30-42"},
                                      {"from_date": "2026-10-12", "to_date": "2026-10-11"},
                                      {"exclude_text": [" "]}, {"seed": True}, {"max_tokens": 0},
                                      {"max_tokens": -1}, {"max_tokens": True}, {"max_tokens": 3.5}])
def test_bad_arguments_leave_no_output(tmp_path, kwargs):
    with pytest.raises(exporter.ExportError):
        export(tmp_path, [selection()], **kwargs)
    assert not (tmp_path / "dataset").exists()


def test_cap_uses_native_rank_and_never_rescues_target(tmp_path):
    kept = selection(0, context="cap included", count=30, target=22)
    missing = selection(1, context="cap excluded", count=30, target=23)
    kept["baseline"].reverse()
    output, manifest = export(tmp_path, [kept, missing])
    record = read_rows(output)[0][1]
    assert len(record["options"]) == 24
    assert {option["label"] for option in record["options"]} == set(exporter.LETTERS)
    assert selected_option(record)["description"] == "合成候选22"
    assert "合成候选23" not in [option["description"] for option in record["options"]]
    assert manifest["quality"]["excluded"]["coverage_outside_cap"] == 1
    assert manifest["none_labels"] == 0


def test_dedup_ignores_ids_ranks_display_models_and_selection_method(tmp_path):
    first = selection(0)
    duplicate = selection(1)
    duplicate["selection"]["method"] = "click"
    duplicate["models"] = [{"choice_id": "model-cannot-label", "status": "ready"}]
    for i, candidate in enumerate(duplicate["baseline"]):
        candidate["id"] = f"different-id-{i}"
        candidate["rank"] = 2 - i
    duplicate["selection"]["candidate_id"] = "different-id-0"
    duplicate["display"] = {"items": []}
    output, manifest = export(tmp_path, [first, duplicate])
    assert manifest["exported_examples"] == 1
    assert manifest["quality"]["excluded"]["duplicate_example"] == 1
    assert read_rows(output)[0][1]["provenance"]["record_ids"] == ["record-0", "record-1"]


def test_conflicting_human_labels_excluded_with_text_free_review(tmp_path):
    first, conflict, repeat = selection(0), selection(1, target=1), selection(2)
    output, manifest = export(tmp_path, [first, conflict, repeat])
    assert manifest["exported_examples"] == 0
    assert manifest["conflicting_examples"] == 1
    assert manifest["quality"]["excluded"]["conflicting_label"] == 3
    review = json.loads((output / "conflicts.jsonl").read_text())
    assert review["records"] == 3 and review["labels"] == 2
    assert set(review) == {"example_hash", "records", "labels"}
    assert first["selection"]["text"] not in json.dumps(review, ensure_ascii=False)


def test_group_union_links_compositions_context_and_suffix_before_dedup(tmp_path):
    # A --same composition--> B --normalized context--> C --composition--> D
    # D --suffix--> E. A duplicate of B links an otherwise separate composition F.
    common = "shared synthetic ending " * 4
    a = selection(0, context="context A", pinyin="a")
    b = selection(1, context="ＨＥＬＬＯ   World", pinyin="NI HAO")
    b["composition_id"] = a["composition_id"]
    c = selection(2, context="hello world", pinyin="ni'hao")
    d = selection(3, context="first prefix " + common, pinyin="test")
    d["composition_id"] = c["composition_id"]
    e = selection(4, context="other prefix " + common, pinyin="test")
    f = deepcopy(b)
    f.update(id="record-5", composition_id="composition-5")
    g = selection(6, context="context G", pinyin="g")
    g["composition_id"] = f["composition_id"]
    output, manifest = export(tmp_path, [a, b, c, d, e, f, g])
    records = read_rows(output)
    assert len(records) == 6
    assert len({split for split, _ in records}) == 1
    assert len({row["group_id"] for _, row in records}) == 1
    assert manifest["split_isolation"]["cross_split_group_overlap"] == 0


def test_deterministic_reordered_input_split_and_remapped_labels(tmp_path):
    rows = [selection(i, context=f"synthetic independent example {i}", pinyin=f"pinyin{i}", target=i % 3)
            for i in range(120)]
    one = tmp_path / "one"
    two = tmp_path / "two"
    three = tmp_path / "three"
    manifest = exporter.export_training(stream(rows), one, seed=101)
    exporter.export_training(stream(list(reversed(rows))), two, seed=101)
    exporter.export_training(stream(rows), three, seed=202)
    assert files(one) == files(two)
    assert manifest["split_isolation"]["all_splits_present"]
    records = {row["id"]: row for _, row in read_rows(one)}
    other = {row["id"]: row for _, row in read_rows(three)}
    assert any(row["options"] != other[key]["options"] for key, row in records.items())
    by_id = {row["id"]: row for row in rows}
    for _, row in read_rows(three):
        expected = by_id[row["provenance"]["record_ids"][0]]["selection"]["text"]
        assert selected_option(row)["description"] == expected
        assert len(row["answer"]) == 1 and row["answer"] in exporter.LETTERS


class FakeTokenizer:
    eos_token = "<synthetic-eos>"

    def __init__(self):
        self.calls = []
        self.encodings = []

    def encode(self, text, *, add_special_tokens):
        assert add_special_tokens is False
        self.encodings.append(text)
        parts = text.split(self.eos_token)
        ids = []
        for index, part in enumerate(parts):
            if index:
                ids.append(1_000_000)
            ids.extend(ord(char) for char in part)
        return ids

    def apply_chat_template(self, messages, **kwargs):
        assert kwargs == {"tokenize": False, "add_generation_prompt": True, "enable_thinking": False}
        assert [message["role"] for message in messages] == ["system", "user"]
        self.calls.append(deepcopy(messages))
        return "<synthetic-chat>" + json.dumps(messages, ensure_ascii=False) + "<assistant>"


def install_tokenizer(monkeypatch, tmp_path, tokenizer):
    directory = tmp_path / "local-tokenizer"
    directory.mkdir()
    calls = []

    class AutoTokenizer:
        @staticmethod
        def from_pretrained(path, **kwargs):
            calls.append((path, kwargs))
            assert kwargs == {"local_files_only": True, "trust_remote_code": False}
            for flag in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"):
                assert os.environ[flag] == "1"
            return tokenizer

    monkeypatch.setitem(sys.modules, "transformers", types.SimpleNamespace(AutoTokenizer=AutoTokenizer))
    return directory, calls


def test_local_tokenizer_appends_label_then_eos_once(monkeypatch, tmp_path):
    tokenizer = FakeTokenizer()
    directory, calls = install_tokenizer(monkeypatch, tmp_path, tokenizer)
    monkeypatch.setenv("HF_HUB_OFFLINE", "original-value")
    output, manifest = export(tmp_path, [selection()], tokenizer_dir=directory)
    assert calls == [(str(directory.resolve()), {"local_files_only": True, "trust_remote_code": False})]
    assert os.environ["HF_HUB_OFFLINE"] == "original-value"
    assert manifest["formats"]["instruction"]["available"]
    split, record = read_rows(output)[0]
    instruction_split, instruction = read_rows(output, "instruction")[0]
    assert split == instruction_split
    assert set(instruction) == {"prompt", "completion"}
    assert instruction["prompt"].endswith("<assistant>")
    assert instruction["completion"] == record["answer"] + tokenizer.eos_token
    assert instruction["prompt"].count(tokenizer.eos_token) == 0
    assert len(tokenizer.encodings) == 24 + 3 + 3  # A-X plus preflight and record boundary/length checks.
    assert tokenizer.encodings[-3:] == [instruction["prompt"], instruction["prompt"] + record["answer"],
                                        instruction["prompt"] + instruction["completion"]]
    count = len(tokenizer.encode(instruction["prompt"] + instruction["completion"], add_special_tokens=False))
    assert record["token_count"] == count
    assert manifest["tokenization"]["checked_examples"] == 1
    assert manifest["tokenization"]["max_observed_tokens"] == count
    assert manifest["tokenization"]["max_tokens_enforced"] is True
    assert manifest["tokenization"]["label_token_ids"] == {letter: [ord(letter)] for letter in exporter.LETTERS}
    assert len(tokenizer.calls) == 2  # Synthetic preflight and the actual training prompt.
    assert json.loads(tokenizer.calls[-1][1]["content"]) == task_from_record(record)


@pytest.mark.parametrize("failure", ["no_eos", "template_failure", "template_not_text", "later_failure"])
def test_tokenizer_failure_is_sanitized_and_atomic(monkeypatch, tmp_path, failure):
    class BrokenTokenizer(FakeTokenizer):
        def apply_chat_template(self, messages, **kwargs):
            self.calls.append(messages)
            if failure == "template_failure" or (failure == "later_failure" and len(self.calls) > 1):
                raise RuntimeError("PRIVATE INPUT MAY APPEAR IN TOKENIZER ERRORS")
            if failure == "template_not_text":
                return [1, 2, 3]
            return "prompt"

    tokenizer = BrokenTokenizer()
    if failure == "no_eos":
        tokenizer.eos_token = None
    directory, _ = install_tokenizer(monkeypatch, tmp_path, tokenizer)
    with pytest.raises(exporter.ExportError, match="Local tokenizer") as error:
        export(tmp_path, [selection()], tokenizer_dir=directory)
    assert "PRIVATE" not in str(error.value)
    assert not (tmp_path / "dataset").exists()
    assert not list(tmp_path.glob(".training-export-*"))


@pytest.mark.parametrize(("failure", "message"), [
    ("multiple_tokens", "every answer letter A-X as one token"),
    ("duplicate_token", "distinct token IDs"),
    ("bad_encoding", "could not encode"),
    ("boundary", "prompt/answer token boundary"),
])
def test_rejects_incompatible_label_tokens_and_boundaries(monkeypatch, tmp_path, failure, message):
    class IncompatibleTokenizer(FakeTokenizer):
        def encode(self, text, *, add_special_tokens):
            ids = super().encode(text, add_special_tokens=add_special_tokens)
            if failure == "multiple_tokens" and text == "X":
                return [1001, 1002]
            if failure == "duplicate_token" and text == "X":
                return [ord("A")]
            if failure == "bad_encoding":
                raise ValueError("PRIVATE TOKENIZER DIAGNOSTIC")
            # The synthetic preflight succeeds; a real prompt then merges its answer.
            if failure == "boundary" and len(text) > 500 and text[-1:] in exporter.LETTERS:
                return ids[:-2] + [1003]
            return ids

    directory, _ = install_tokenizer(monkeypatch, tmp_path, IncompatibleTokenizer())
    with pytest.raises(exporter.ExportError, match=message) as error:
        export(tmp_path, [selection()], tokenizer_dir=directory)
    assert "PRIVATE" not in str(error.value)
    assert not (tmp_path / "dataset").exists()
    assert not list(tmp_path.glob(".training-export-*"))


def test_exact_token_limit_includes_eos_and_does_not_truncate(monkeypatch, tmp_path):
    tokenizer = FakeTokenizer()
    directory, _ = install_tokenizer(monkeypatch, tmp_path, tokenizer)
    first = tmp_path / "first"
    manifest = exporter.export_training(stream([selection()]), first, tokenizer_dir=directory)
    count = manifest["tokenization"]["max_observed_tokens"]
    exact = tmp_path / "exact"
    exporter.export_training(stream([selection()]), exact, tokenizer_dir=directory, max_tokens=count)
    assert read_rows(first) == read_rows(exact)
    assert read_rows(first, "instruction") == read_rows(exact, "instruction")
    empty_target = tmp_path / "still-empty"
    empty_target.mkdir()
    with pytest.raises(exporter.ExportError, match=f"{count} tokens, exceeding max-tokens={count - 1}"):
        exporter.export_training(stream([selection()]), empty_target, tokenizer_dir=directory, max_tokens=count - 1)
    assert list(empty_target.iterdir()) == []
    assert not list(tmp_path.glob(".training-export-*"))


def test_default_2048_rejects_large_example_atomically(monkeypatch, tmp_path):
    directory, _ = install_tokenizer(monkeypatch, tmp_path, FakeTokenizer())
    rows = [selection(), selection(1, context="SYNTHETIC_OVERSIZE " * 200)]
    with pytest.raises(exporter.ExportError, match="max-tokens=2048; export aborted without truncation") as error:
        export(tmp_path, rows, tokenizer_dir=directory)
    assert "SYNTHETIC_OVERSIZE" not in str(error.value)
    assert not (tmp_path / "dataset").exists()
    assert not list(tmp_path.glob(".training-export-*"))


def test_nonlocal_tokenizer_rejected_without_import(tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, "transformers", None)
    with pytest.raises(exporter.ExportError, match="existing local"):
        export(tmp_path, [selection()], tokenizer_dir="https://synthetic.invalid/tokenizer")


@pytest.mark.parametrize("kind", ["nonempty", "file", "symlink"])
def test_refuses_existing_data(tmp_path, kind):
    output = tmp_path / "dataset"
    sentinel = tmp_path / "private-sentinel"
    sentinel.mkdir()
    (sentinel / "keep").write_text("keep this")
    if kind == "nonempty":
        output.mkdir()
        (output / "keep").write_text("keep this")
    elif kind == "file":
        output.write_text("keep this")
    else:
        output.symlink_to(sentinel, target_is_directory=True)
    with pytest.raises(exporter.ExportError, match="new or empty"):
        exporter.export_training(stream([selection()]), output)
    assert (sentinel / "keep").read_text() == "keep this"
    assert not list(tmp_path.glob(".training-export-*"))


def test_empty_output_directory_and_text_stream(tmp_path):
    output = tmp_path / "dataset"
    output.mkdir()
    text = stream([selection()]).getvalue().decode()
    manifest = exporter.export_training(io.StringIO(text), output)
    assert manifest["exported_examples"] == 1


@pytest.mark.parametrize(("limit", "value", "rows", "message"), [
    ("MAX_RECORDS", 1, [selection(), correction("record-0")], "record limit"),
    ("MAX_INPUT_BYTES", 10, [selection()], "byte limit"),
    ("MAX_LINE_BYTES", 10, [selection()], "Input line exceeds"),
])
def test_bounded_input_fails_clearly(monkeypatch, tmp_path, limit, value, rows, message):
    monkeypatch.setattr(exporter, limit, value)
    with pytest.raises(exporter.ExportError, match=message):
        export(tmp_path, rows)
    assert not (tmp_path / "dataset").exists()


def test_invalid_json_schema_event_are_counted_without_text(tmp_path):
    data = b'not-json-private\n{"schema_version":1,"event_type":"secret-event"}\n[]\n{"schema_version":true}\n{"schema_version":2}\n{"x":NaN}\n'
    manifest = exporter.export_training(io.BytesIO(data), tmp_path / "dataset")
    assert manifest["quality"]["input_events"] == 6
    assert manifest["quality"]["excluded"] == {"invalid_json": 2, "unsupported_event": 1, "unsupported_schema": 3}
    assert "private" not in json.dumps(manifest) and "secret-event" not in json.dumps(manifest)


@pytest.mark.parametrize("raw", [b'\xff\n', b'{"schema_version":1,"private":"\\ud800"}\n'])
def test_invalid_utf8_fails_without_echo(tmp_path, raw):
    with pytest.raises(exporter.ExportError, match="UTF-8 at line 1"):
        exporter.export_training(io.BytesIO(raw), tmp_path / "dataset")


def cli(tmp_path, arguments, *, data=None, fake_tokenizer=False):
    guard = tmp_path / "guard"
    guard.mkdir(exist_ok=True)
    (guard / "sitecustomize.py").write_text(
        "import socket\n"
        "def forbidden(*args, **kwargs):\n    raise AssertionError('NETWORK BLOCKED')\n"
        "socket.create_connection = forbidden\nsocket.getaddrinfo = forbidden\n"
        "socket.socket.connect = forbidden\nsocket.socket.connect_ex = forbidden\n"
    )
    if fake_tokenizer:
        (guard / "transformers.py").write_text(
            "import os\n"
            "class AutoTokenizer:\n"
            "    eos_token = '<eos>'\n"
            "    @classmethod\n"
            "    def from_pretrained(cls, path, **kwargs):\n"
            "        assert os.path.isdir(path)\n"
            "        assert kwargs == {'local_files_only': True, 'trust_remote_code': False}\n"
            "        assert os.environ['HF_HUB_OFFLINE'] == '1'\n"
            "        return cls()\n"
            "    def encode(self, text, *, add_special_tokens):\n"
            "        assert add_special_tokens is False\n"
            "        return [ord(c) for c in text]\n"
            "    def apply_chat_template(self, messages, **kwargs):\n"
            "        assert kwargs == {'tokenize': False, 'add_generation_prompt': True, 'enable_thinking': False}\n"
            "        return messages[0]['content'] + messages[1]['content'] + '<assistant>'\n"
        )
    else:
        (guard / "transformers.py").write_text("raise AssertionError('No tokenizer import expected')\n")
    root = Path(__file__).resolve().parents[1]
    return subprocess.run([sys.executable, str(root / "scripts" / "export_training.py"), *map(str, arguments)],
                          input=data, capture_output=True, timeout=20, cwd=tmp_path,
                          env={**os.environ, "PYTHONPATH": str(guard), "PYTHONDONTWRITEBYTECODE": "1"})


@pytest.mark.parametrize("use_file", [False, True])
@pytest.mark.parametrize("tokenizer", [False, True])
def test_cli_stdin_and_input_path_offline(tmp_path, use_file, tokenizer):
    output = tmp_path / "dataset"
    data = stream([selection()]).getvalue()
    args = ["--output", output, "--seed", "21", "--app", "synthetic.app", "--app", "other.app",
            "--from-date", "2026-10-11", "--to-date", "2026-10-11", "--exclude-text", "blocked",
            "--exclude-text", "also blocked", "--include-corrected"]
    if use_file:
        source = tmp_path / "synthetic.jsonl"
        source.write_bytes(data)
        args.extend(["--input", source])
        data = None
    if tokenizer:
        directory = tmp_path / "tokenizer"
        directory.mkdir()
        args.extend(["--tokenizer", directory])
    result = cli(tmp_path, args, data=data, fake_tokenizer=tokenizer)
    assert result.returncode == 0, result.stderr.decode()
    manifest = json.loads(result.stdout)
    assert manifest["exported_examples"] == 1
    assert manifest["formats"]["instruction"]["available"] == tokenizer
    assert result.stderr == b""
    assert b"MODEL_SECRET" not in result.stdout
    assert selection()["context"]["text"].encode() not in result.stdout


def test_cli_error_is_text_free_and_does_not_overwrite(tmp_path):
    output = tmp_path / "dataset"
    output.mkdir()
    (output / "keep").write_text("do not touch")
    result = cli(tmp_path, ["--output", output], data=stream([selection()]).getvalue())
    assert result.returncode == 2 and result.stdout == b""
    assert b"new or empty directory" in result.stderr
    assert (output / "keep").read_text() == "do not touch"
    result = cli(tmp_path, ["--output", tmp_path / "missing-output", "--input", tmp_path / "PRIVATE-name"])
    assert result.returncode == 2
    assert b"PRIVATE" not in result.stderr and b"Traceback" not in result.stderr


def test_cli_explicit_stdin_dash(tmp_path):
    result = cli(tmp_path, ["--input", "-", "--output", tmp_path / "dataset"],
                 data=stream([selection()]).getvalue())
    assert result.returncode == 0, result.stderr.decode()
    assert json.loads(result.stdout)["exported_examples"] == 1


def test_cli_max_tokens_is_explicit_with_and_without_tokenizer(tmp_path):
    directory = tmp_path / "tokenizer"
    directory.mkdir()
    data = stream([selection()]).getvalue()
    result = cli(tmp_path, ["--output", tmp_path / "too-small", "--tokenizer", directory, "--max-tokens", "1"],
                 data=data, fake_tokenizer=True)
    assert result.returncode == 2 and result.stdout == b""
    assert b"max-tokens=1" in result.stderr and b"without truncation" in result.stderr
    assert not (tmp_path / "too-small").exists()
    result = cli(tmp_path, ["--output", tmp_path / "unchecked", "--max-tokens", "1"], data=data)
    assert result.returncode == 0, result.stderr.decode()
    manifest = json.loads(result.stdout)
    assert manifest["limits"]["max_tokens"] == 1
    assert manifest["tokenization"]["max_tokens_enforced"] is False
    assert manifest["tokenization"]["reason"] == "local_tokenizer_required"
    assert "token_limit_unchecked_without_local_tokenizer" in manifest["warnings"]
