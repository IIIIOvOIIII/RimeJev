# Validation — 0.2.4 public source

The original development version passed 96 backend tests and 84 real-Rime regression probes. It was installed on an Apple Silicon Mac, and the user confirmed that a recommendation appeared in the second slot and digit 2 committed it correctly. These observations belong to that development installation, not every macOS host.

The public package preserves the ranking/placement, context, and timing logic. Publication changes remove machine-specific paths and credential-service defaults, make the quality gate self-contained, and replace private dictionary snapshots with deterministic synthetic Rime fixtures. No credential, learned user dictionary, screenshot of a user's applications, runtime log, or model weight is published.

The engine probes use controlled recommendation responses, not real model calls. They verify candidate identity, unchanged first choice, second-slot placement, relative order/count, submission, stale handling, restoration, and repeated application. Model accuracy and visual acceptance must be reported separately.

The local model and Jev can make an incorrect or low-confidence choice. Cold loading/network setup may exceed the display deadline, in which case native ordering remains. No bulk model evaluation is part of installation.

Public source verification completed on 2026-10-11 (Asia/Singapore):

| Check | Result |
| --- | --- |
| Locked dependency setup | `uv sync --frozen` succeeded in a separate Python 3.13 environment |
| Public bootstrap | Pinned official upstream fetched and verified; idempotent rerun passed |
| Backend and standalone-gate tests | 128 passed; backend line coverage 85.40% |
| Native tests | Coordinator, context continuity, and all source-label variants passed; coordinator line coverage 85.79% |
| Real-Rime regression | 86 isolated synthetic-fixture probes passed, without personal dictionary data |
| Native build | arm64 build and ad-hoc signature verification passed |
| Credential scan | Gitleaks 8.30.1 reported no findings in the public Git history |

The public package was built and tested, but not installed over the already accepted development installation during publication. Public credential endpoints/helpers remain intentionally unconfigured. Fresh-user OS permission and per-host typing acceptance must follow `LLM_INSTALL.md`.

The published history starts from a sanitized source snapshot. Private development history, private setup evidence, local configuration, credentials, models, and personal dictionaries are not included.
