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


## 0.3.0 Tev and model timeout validation

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

Final deployment preflight passed on source commit `cc2c4fc819308b8a50dafe6b218a8ba833a284fc`:

| Check | Result |
| --- | --- |
| Python tests | 341 passed; backend line coverage 89.31% |
| Native coordinator | Passed; line coverage 91% |
| Context, badges, timeout persistence, runtime switching | Passed, including adopted processes, delayed release, failed unload/retry, download-triggered reload and stale responses |
| Real-Rime engine | 168 isolated synthetic-fixture probes passed across all four provider identities |
| Native build and installation | arm64 0.3.0 built, signed and installed; installed binary and Lua match the verified source |
| Installed settings window | Correct model list; 4B default 2s; custom 3.2s and 1.1s values remain independent across switching; invalid 0.1s rejected; reset returns to 2s/0.6s; 4B visibly ready |
| Credential/metadata checks | Gitleaks found no leaks in staged changes or the three-commit source history; all 83 tracked files passed private-metadata checks |

The first installation smoke check ran before macOS exposed the refreshed input source. One bounded registration/enablement retry through the installed app resolved it; the subsequent read-only smoke passed. An ownerless legacy TT socket was archived only after confirming no process/listener owned it. Source registration and stale-process cleanup are not model-quality evidence.

The system Ollama remained 0.33.2 on its original port; the isolated Tev service is 0.40.3. Existing user application choices and TT weight paths were preserved during migration. Only non-secret credential-service metadata was migrated locally; none was published.

Actual settings interaction was observed. Fresh manual typing acceptance for 0.3.0 has been requested separately; the earlier user acceptance belongs to 0.2.4. Model choice is not proof of correct Chinese predictions across all contexts.

## 0.4.0 dual models, direct key entry and Shift feedback

Final installed code is `1b1f713df440ef4cfb4e2ca97ad5c15c244077a7`. Local deployment and read-only installation smoke passed after the full preflight. macOS requested input-method enablement; that visible prompt was accepted under the existing installation authorization. Earlier automation still using Apple Pinyin is not recorded as Rime acceptance.

| Check | Evidence |
| --- | --- |
| Python | 396 tests passed; backend line coverage 90.19% |
| Native coordinator | Passed; core line coverage 91.5%; independent dual deadlines and selection-lock behavior covered |
| Candidate planner and real Rime | 66 planner cases; 437 engine probes, including slots 2/3, numeric selection, both priorities, same-word merging, partial responses and stale payloads |
| Runtime integration | Cloud/local coexistence, one-local replacement, credential revision during rapid changes, blocked Keychain authorization without blocking local, local-pressure/cloud-response independence, and stale callbacks passed against isolated processes |
| Installed settings | Four modes and three local choices visible; both Up and Down work; order/local choice persist across mode changes; both Jev+TT and Jev+Tev0.8B displayed ready |
| Key UI | Secure field masked an unsaved synthetic value; that value was cleared; empty save rejected; real credentials were not replaced |
| Credential logic | Keychain SecItem queries/write/read/replace/delete tested with injected Security APIs; bounded stdin transport and runtime construction tested using synthetic credentials |
| Shift | User confirmed the Chinese/English indicator after real Shift input on the first 0.4 build. The final patch only fixes settings opening before the first candidate panel and leaves the Shift implementation unchanged |
| Installation | Version/name/signature, installed binary receipt, deployed Lua, input source and original Squirrel preservation passed |

A regression-test race exposed overlapping teardown between independent fake managers sharing test sockets. Tests now drain each manager before starting the next fixture; the runtime also stops superseded reconciliation between providers. Full preflight passed after correction. These diagnostics were not counted as successful runs.

Existing application modes, custom timeout values and credential source were preserved; temporary UI selections were restored. No new real API key was saved and no live authentication with a newly entered key is claimed. Engine placement, actual settings interaction, user-confirmed Shift behavior and real-model prediction quality are distinct evidence scopes. Original provider thresholds and model identities were not changed to force predictions.
