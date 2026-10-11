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


## 0.3.0 Tev and model timeout validation (in progress)

The four active identities are `jev`, `local` (TT), `tev-0.8b`, and `tev-4b`; both Tev sizes display `✦ Tev`. Three local models were loaded and exercised with fixed synthetic inputs. Selected-model shutdown was followed by an empty managed-service `/api/ps` list. The original system service was not replaced.

Ollama 0.40.3 serves the Tev decision API with the pinned Apple Silicon MLX manifests, verified directly against the official registry index and manifest blobs. The runtime binary requires macOS 14 or newer. The source remains free of model weights, credentials, and private settings.

The bounded Tev ledger includes eight diagnostic decisions plus startup warmups; earlier failures and timeouts are retained. Some initial inputs used intentionally long synthetic engine-fixture words; later tests used short common candidate words. These runs are protocol/latency diagnostics, not an accuracy benchmark, and other build work may overlap timing measurements.

| Fixed diagnostic | Result |
| --- | --- |
| TT local load and inference | Ready; returned valid candidate probabilities |
| Tev 0.8B load and inference | Ready; two Chinese examples had insufficient confidence and would keep native order |
| Tev 4B: 汽车 + youxiang, 2-second window | 油箱, probability about 0.90; 798ms model response, within the configured window including debounce |
| Tev 4B: 我现在又想 + sj, 4-second diagnostic window | 1.58s response but low confidence; recommendation rejected and native order retained |

User-approved timeout controls allow 0.3–10 seconds per model. Defaults are 0.6s for Jev, TT and Tev 0.8B; 2s for Tev 4B. Tests cover independent values, persistence-compatible optional settings, invalid/NaN/boundary values, remaining runtime budgets, deadlines, selection locks, and stale variants. Native lifecycle tests include a release slower than the initial three-second wait and verify automatic continuation without another key.

The backend suite currently passes 331 tests, and 168 real-Rime fixture probes cover all four sources. Build/install/actual settings-window validation will be recorded after the final gate. Model choice is not proof of correct Chinese predictions across all contexts.
