# RimeJev progress

## 2026-10-11 — baseline published

Version 0.2.4 was published at https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.2.4 before beginning the next requested feature. The public baseline is 524e1c34e6224d79190ff7d72398296677f59557, with bilingual README and LLM_INSTALL.md. No private history or credentials were published.

## 2026-10-11 — Tev local model selection implemented

User requested selectable this-that-model, Tev 0.8B, and Tev 4B, with source labels exactly `✦ Jev`, `✦ TT`, and `✦ Tev`. Keep the original-first / recommendation-second policy and immediate native fallback.

Official Tev and Ollama documentation verifies local decision inference through `/v1/systemone`; support requires Ollama 0.35 or newer. Use a separately managed, pinned 0.40.3 process on loopback port 11435 to avoid changing the existing system Ollama service. Limit Tev to 23 genuine candidates plus `none`, within its trained 24-option range. Local modes never fall back to cloud. Model weights and runtime binaries remain ignored local resources.

Implementation was developed on `feat/tev-model-selection`, reviewed, and fast-forwarded to `main` as `cc2c4fc819308b8a50dafe6b218a8ba833a284fc`. The full gate passed before installation. Detailed validation is recorded once in `docs/VALIDATION.md`.

### Integration evidence and timeout settings

Both pinned Mac MLX Tev manifests have been downloaded and verified. Ollama 0.40.3 successfully served the local decision API using its MLX variants; older documentation claiming GGUF-only support does not describe this verified runtime. The existing system service was not upgraded or replaced.

Real fixed-input tests confirm loading, decisions, and selected-model unload for both Tev variants. The 4B model correctly selected 油箱 in the car context, but its roughly one-second response exceeded the previous 600ms placement window. Some 23-option requests exceeded the former 1500ms request limit; 0.8B produced lower confidence on the two tested Chinese examples. These are bounded diagnostics, not a Chinese accuracy benchmark.

The user explicitly approved a 2-second default for Tev 4B and requested a configurable timeout for every model. Add settings for each active provider, 0.3–10 seconds, with defaults TT/Jev/Tev0.8B=0.6s and Tev4B=2s. Time is measured from the last stable input, includes debounce/sampling, and remaining time is passed to the runtime. Input/selection locks and first-candidate preservation remain in force.

Native lifecycle regression now includes a delayed shutdown exceeding the old three-second wait and verifies automatic continuation without another key. The native adapter also verifies adopted runtimes (without a Process handle) finish release before another model starts, and successful model downloads reload the still-selected provider. Python shutdown waits for in-flight work and unload before socket removal; failed unload must preserve ownership and report failure. Full integration, installation smoke and real settings-window checks passed. Native input placement was verified by 168 real-engine probes. New manual typing acceptance was requested separately and must not be inferred from settings interaction.

### Release readiness

341 Python tests, 91% native coordinator line coverage, backend 89.31%, native build/signature and installed smoke passed. Actual settings checks proved model switching, independent custom timeout values, invalid-value rejection and per-model reset. Existing per-app configuration was preserved during migration; temporary settings used by UI verification were restored; application choices changed separately during verification were retained. Release documentation is bilingual, with `LLM_INSTALL.md` dedicated to installation assistants. Public sources contain neither local settings nor credentials; the earlier `v0.2.4` release remains unchanged.

## 2026-10-11 — 0.4.0 dual-model settings in progress

- Current work: implement four enhancement modes, one selectable local backend alongside Jev, user-ordered priority, Keychain-backed masked API key entry, and Shift Chinese/English indication.
- Expected: preserve native first; annotate a model match there; otherwise place unique recommendations in slots two/three by configured priority. Matching duplicate recommendations merge source labels. Missing/late results retain native words. Independent model deadlines and selection locks remain.
- Scope: local development and installation authorized. Use deterministic dual-provider/Rime tests, existing targeted checks, full preflight and installed smoke; at most two fixed synthetic live decisions per provider if needed. Do not tune thresholds to force a demonstration. Max five recovery attempts per failure class. Secrets never enter source, settings, logs or argv.
- Result: implementation started from clean 0.3.0 main. Next: integrate and review, then build/deploy and actual settings/Shift checks.

### Integration milestone

- Result: dual candidate planning and 437 real-Rime probes pass; independent-deadline coordinator tests and concurrent runtime tests pass. Native settings, model migration and separate Shift HUD compile. Python suite passes 396 tests. Keychain/storage and bounded stdin tests use synthetic credentials only.
- Review corrections: credential revisions survive rapid local-model changes; pending Keychain authorization runs on a separate queue; local memory pressure invalidates local work without discarding cloud results. Isolated native lifecycle tests exercise all three cases.
- Next: final credential scan and deploy-preflight, local install, actual settings/HUD interaction. Preserve user timeouts and per-app modes; no automatic secret migration or new cloud enablement.

### 2026-10-11 — local deployment and verification complete

- Current work: 0.4.0 implementation and local verification completed; final installed source `1b1f713df440ef4cfb4e2ca97ad5c15c244077a7`.
- Expected result: requested dual modes/priority, secure direct-key settings and Shift feedback, preserving existing input and settings.
- Result: achieved at code/install/test scope. Full preflight and installed smoke passed. Actual settings showed four modes, all local models, working Up/Down order, persisted selections, masked input and concurrent backend readiness. User confirmed real Shift language feedback. Key storage/transport used synthetic test data; no real key replacement was needed. See VALIDATION.md for evidence boundaries.
- Cleanup: unsaved UI test text cleared, temporary model/priority changes restored, existing user timeouts and credential source retained. Original app/data remain recoverable. Code and bilingual installation documentation are on `feat/dual-model-settings`; no new formal release tag is created by this local-deployment task.
- Next: user can enable cloud + local in any chosen application and save their own API key through the secure field if desired. No required implementation work remains in this request.

## 2026-10-11 — GitHub v0.4.0 release package

- Current work: user requested publication of the locally verified version to GitHub main and the v0.4.0 release.
- Expected result: publish the tested runtime together with bilingual documentation and a tag-pinned LLM installation guide; exclude all credentials, local settings, personal dictionaries and model weights.
- Result: source-package preparation achieved. The preflight source receipt was recomputed and matches `1b1f713df440ef4cfb4e2ca97ad5c15c244077a7`; subsequent changes are documentation only. README and LLM_INSTALL now select `v0.4.0`. Runtime behavior is unchanged from the installed version.
- Publication record: [GitHub v0.4.0](https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.4.0). Remote main/tag identity and the published release record are verified at publication; local evidence stays outside the repository.
- Next: normal use and issue-driven fixes. This publication does not require another local app installation.

## 2026-10-11 — 0.4.1 all-application defaults

- Current work: add global default mode/local backend/priority plus explicit application overrides and a follow-default action.
- Expected: unconfigured apps inherit defaults without allowlist enrollment; explicit per-app choices including off remain authoritative. Default changes invalidate existing requests. Secure input and the input method's own settings are excluded.
- User choice: keep the new global default off initially; do not enable cloud or local enhancement globally during installation or live UI checks.
- Scope: focused native settings/UI change, isolated settings/migration tests and existing required gate; local installation follows successful preflight. No real model or credential calls are needed for verification. At most five recovery attempts per failure class.
- Next: implement and validate profile resolution, persistence and UI scope switching, then local deployment.

### Implementation checks

- Global/app resolution and persistence tests passed across eight groups and six separate loader scenarios using the actual Settings implementation and disposable storage. Existing native compilation and signature verification passed.
- The previous allowlist gate was removed; secure input, empty app identities and the IME's own settings stay ineligible. Global edits invalidate/rebuild existing coordinators; reused controllers refresh on app identity changes.
- Next: complete the required preflight, install locally and inspect the live scope UI while leaving the global default off.

### 2026-10-11 — 0.4.1 installed and verified

- Current work: completed global defaults and per-application overrides, installed source `8138c198ab16225026039b4c56969db9f617bc96`.
- Result: full preflight and installed smoke passed. Isolated production-Settings tests passed all eight logic groups and six loader scenarios. Actual UI shows global-off, current-app override and follow-default controls. Existing app modes/local choices/order/timeouts/credential metadata were compared with the pre-install snapshot and are unchanged.
- User preference honored: no global model was enabled during installation or UI verification. The settings window was returned to global defaults, still off. Live model-quality testing is unnecessary for this settings-only feature.
- Next: the user can select one global default whenever desired; unconfigured apps inherit automatically. The feature branch and bilingual instructions are synchronized; no required work remains for this request.

## 2026-10-11 20:48 SGT — GitHub v0.4.1 release package

- Current work: user authorized merging 0.4.1 into main and publishing the GitHub release.
- Expected result: publish all-application defaults and explicit app overrides with bilingual documentation and a tag-pinned LLM installation guide, excluding secrets and local data.
- Result: source-package preparation achieved. The tested receipt matches `8138c198ab16225026039b4c56969db9f617bc96`; subsequent changes are Markdown only. README and LLM_INSTALL now select `v0.4.1`. Existing preflight and local installation evidence remain applicable.
- Publication record: [GitHub v0.4.1](https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.4.1). Remote main/tag identity, final credential scan and the published release record are checked during publication; detailed receipts remain outside the repository.
- Next: complete the final scan, fast-forward main and publish/verify the release. No runtime reinstall or settings changes are required; the live global default remains off.

## 2026-10-11 — 0.4.2 current-line context (approved)

- Current work: implement the approved current-line context reader and permit candidate decisions with empty preceding text.
- Expected result: use existing/pasted text before the composition in the same logical line, with an 80-character limit, stable request identity and original-candidate fallback. Preserve all existing user settings, including the latest global profile.
- Scope: native reader/integration, bounded regression tests, full preflight and local deployment; no GitHub main merge or release tag in this task. Per failure class, at most five recovery attempts; use synthetic host text and small live acceptance checks, no bulk model evaluation.
- Result: baseline inspected at v0.4.1 (`1f227b4`); implementation beginning.
- Next: implement/test bounded context snapshots and provider empty-context behavior, then build/install and verify actual typing.

### Implementation and review

- Current work: bounded same-line snapshots, native integration and empty-context provider instructions implemented.
- Result: initial native build/signature and context/parser tests passed; 423 Python tests passed. Focused provider tests cover TT, Jev and both Tev sizes without real credentials or calls. Review caught unknown-caret equality and redundant eager reads: unbound cursors now abstain, and acquisition coalesces behind the existing debounce with read time deducted from model deadlines.
- Latest local preference: the user has since selected a dual-model global default. Preserve the current profile as found, rather than restoring the historical off choice. No settings are changed for implementation tests.
- Limitation: the public IMK read API is synchronous; no unsupported background-thread calls are introduced. Bounded reads, debounce and five-second backoff reduce repeated slow-host work, but cannot interrupt the first host call. Live host timing remains to be checked.
- Next: finish actual adapter integration tests and full preflight, then local install and synthetic host acceptance.

- Adapter integration result: 15 actual-adapter/main-runloop scenarios passed with in-memory host/runtime boundaries. Fresh pasted text and known-position empty context dispatch and apply; unknown position, changed text/caret and superseded work are rejected. Both provider priorities and remaining deadline accounting pass. Full Rime/UI checks follow separately.

### Deployment restart correction

- Initial preflight and installation smoke passed at `5a52bb5`, but live diagnostics exposed an old-code process automatically relaunched while files were being copied. This was not counted as new-feature acceptance.
- Fix: on updates, temporarily release a selected RimeJev source, await the previous process exiting, replace/build/register, then restore the same source if the user has not changed selection. Other input-source choices remain unchanged. Status now includes the running bundle version; installation records the actual preserved global mode.
- Next: rerun the exact-source gate and installation, then resume synthetic typing validation.

### 2026-10-11 — final 0.4.2 deployment

- Current work: installed `d53c20e8815ce88a13e5fd4caa53772902be88b2` after the second full exact-source preflight.
- Result: build/signature, 423 backend tests, all native suites, 15 adapter cases, 437 real-Rime probes and installed smoke passed. Running version is 0.4.2 and the installed binary matches its receipt. Every saved setting is unchanged; current global mode remains dual.
- Live scope: current-line reads/model requests observed, but automation reported TextEdit rather than the dedicated host. The user subsequently confirmed a model recommendation for existing text + a ten-second pause + manual sj in the dedicated 0.4.2 host.
- Result: core manual typing acceptance is complete. Newline/middle-insertion/empty-context checks are isolated code/adapter evidence; no universal app compatibility or particular model prediction is claimed.
- Next: normal use and issue-driven fixes; no required development/deployment work remains. Recoverable 0.4.1 backups are retained. Code is on the feature branch; no main merge or formal 0.4.2 release in this local-deployment task.

## 2026-10-11 — 0.5.0 opt-in training capture (approved)

- Current work: implement the approved local encrypted capture, application/directory controls and offline training export.
- Expected result: default off independently of enhancement; bind observed candidate/context/model/display/selection records; preserve user configuration and leave capture off after local deployment.
- Scope/budget: native capture/UI, encrypted bounded writer, local export and synthetic tests; no real private input collection, no model training/upload, no main merge or release tag. At most five recovery attempts per failure class, one full final preflight unless changes require repeating it.
- Result: clean 0.4.2 feature baseline verified at b0d7af6.
- Next: implement disjoint storage/export components and native event integration, then review, tests, backup/install and default-off UI verification.

### Implementation and isolated verification

- Current work: all capture/settings/storage/export components implemented. Defaults remain off, empty selected-app scope and independent of enhancement.
- Result: collector privacy/scope/commit/rollback tests, 17 actual adapter scenarios, 15 encrypted-storage suites and 75 exporter tests passed. Actual collector→AES-GCM file→off-main decryption→Python export passed three synthetic pipelines, including human/model disagreement and correction exclusion. Native UI validation and initial build/signature passed. No real input or real Keychain key was used by automated tests.
- Review fixes: unavailable context stays null; undone partial choices are pruned and commit chains validated; model opt-out removes source annotations; custom missing directories never recreate; disable acknowledgement follows worker quiescence; training instruction files now match the official prompt/completion contract with local tokenizer/token-boundary checks.
- Next: exact-source full preflight, backup/install, confirm default-off UI and narrowly scoped synthetic live acceptance, then restore default-off configuration.

### 2026-10-11 — 0.5.0 installed and accepted locally

- Current work: completed deployment of tested source `7cdde9e6ad3cc4375110d241b6bbfc3bec8a131b` and installed UI acceptance.
- Expected result: independent off-by-default capture, selectable directory/apps, accurate observed choice records, local encrypted storage and offline export.
- Result: achieved. Full gate and final installed smoke passed. Live dedicated-app typing generated one encrypted sample with correct context/pinyin/digit selection and two model results; installed-app Keychain decryption, one-example export, model/label separation, automatic stop and recoverable deletion passed. Temporary plaintext was removed.
- Final state: capture is off and the test app is removed. Latest path/scope choices observed during closeout were preserved; all existing enhancement settings remain unchanged. No normal-app capture was observed, no dataset uploaded and no model trained.
- Next: user may choose their desired capture scope/path and explicitly enable collection. No required implementation/deployment work remains. Feature branch publication only; main/release remain unchanged.

## 2026-10-11 23:45 SGT — GitHub v0.5.0 release package

- Current work: user authorized merging 0.5.0 into main and publishing the GitHub release, with bilingual README and a fixed-version LLM installation guide.
- Expected result: publish current-line context and opt-in encrypted capture while keeping capture off by default and excluding private datasets, dictionaries and credentials.
- Result: source-package preparation achieved. The tested source receipt and installed binary match `7cdde9e6ad3cc4375110d241b6bbfc3bec8a131b`; subsequent changes are Markdown only. Both README languages and LLM_INSTALL select `v0.5.0` and distinguish optional capture from model enhancement. Source/default installation settings are off with an empty selected-app list; the live capture switch also remains off. No settings or runtime files were changed for publication.
- Package boundary: all 114 tracked paths and source-archive entries were inspected; only documented synthetic evaluation/test fixtures are included. All 19 existing commits passed the credential scan, and 235 historical blobs contain no private-machine metadata or binaries. Collected records, exports, personal dictionaries, credentials, local settings, binaries, models and backups remain outside the release.
- Publication target: [GitHub v0.5.0](https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.5.0). Main and the annotated tag will identify the same release commit. Final scan and remote verification receipts remain in ignored local evidence.
- Next step: complete the final Git-history credential scan, fast-forward main, create the source-only release, and verify remote refs and published documentation. The installed 0.5.0 runtime needs no reinstall.

## 2026-10-11 — 0.5.1 daily compression and rolling retention (approved)

- Current work: add compressed-before-encryption daily capture files and oldest-first cleanup at the configured quota, then local deployment.
- Expected result: keep newest input without pausing at normal capacity pressure; preserve capture consent, selected path/apps and all enhancement settings.
- Policy: local calendar-day files, LZFSE payload compression before AES-GCM, read compatibility with 0.5.0; projected 90% quota triggers permanent oldest-file cleanup toward 80%. Manual deletion still uses Trash. Existing closed legacy files are compacted atomically when capture next writes; disabled/read-only operations do not migrate/delete.
- Scope/budget: storage/UI/docs and meaningful synthetic storage/pipeline tests; full exact-source preflight and local smoke. No real private-data test collection or training, no formal main merge/release. Target one focused development/deployment pass; max five recovery attempts per failure class.
- Result: clean v0.5.0 baseline 79e1d88 inspected; implementation in progress.
- Next: implement and test compression, migration, retention and compatibility, then deploy and verify settings preserved.

### 2026-10-12 — isolated storage and export verification

- Current work: implemented compressed-before-encryption v2 envelopes, local-day/size rotation, atomic legacy compaction and 90%→80% oldest-first retention; UI describes permanent cleanup and shows reclaimed space.
- Expected result: smaller encrypted files, continued writes under quota pressure, preserved legacy records and private boundaries.
- Result: achieved in isolated tests. All 24 storage suites and the three actual capture/storage/export pipelines passed. Schema AAD, bounded decompression, legacy compatibility, migration failure preservation, date/mtime ordering, key/path/configuration races and unrelated-file retention are covered. Source typecheck passed. No user data or real key was used by these tests.
- Next step: final review, exact-source full preflight, local deployment, running-version/settings/UI verification. The live capture switch is off and its existing settings have been backed up.

### 2026-10-12 00:07 SGT — 0.5.1 deployed and verified

- Current work: completed local installation of `186487664e1c5d974eaed86792c7f4a560b0957a` after its exact-source full preflight.
- Expected result: daily compressed/encrypted storage and oldest-first retention available locally, with user settings preserved.
- Result: achieved. Backend/native/build/lint and real-Rime checks passed; installed read-only smoke confirms running 0.5.1 and matching binary. Actual settings UI shows the compression/90%→80% permanent-cleanup explanation and counters. Saved configuration matches the immediate pre-install snapshot; capture remains off, with user path/app scope preserved. No private input was used to test deletion.
- Publication: implementation is on `feat/training-retention`; closure documentation is synchronized there. This task does not create a formal release. Local receipts and backups stay ignored.
- Next step: normal use. When the user explicitly enables capture, new writes use compression, older eligible files may be compacted, and capacity pressure retires oldest segments automatically. No required implementation/deployment work remains.

## 2026-10-12 00:11 SGT — GitHub v0.5.1 release package

- Current work: user authorized merging 0.5.1 into main and publishing a GitHub release with bilingual README and LLM_INSTALL synchronized.
- Expected result: publish daily compressed capture and oldest-first retention; preserve off-by-default consent and exclude all private datasets, dictionaries and credentials.
- Result: source-package preparation achieved. The original tested-source digest and installed binary match `186487664e1c5d974eaed86792c7f4a560b0957a`; subsequent changes are Markdown only. README and LLM_INSTALL now select `v0.5.1` and explain the format compatibility boundary. Source/installer defaults and the current live capture switch are off.
- Publication target: [GitHub v0.5.1](https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.5.1). Main and the annotated tag will resolve to the same release commit; only source archives will be provided.
- Next step: complete the full-history/private-file audit, fast-forward main and create the release, then verify remote refs, notes and downloaded archive. Detailed final receipts stay under ignored local evidence. No runtime reinstall or user settings changes are needed.

## 2026-10-15 23:49 SGT — 0.5.2 punctuation candidate paging

- Current work: user requested comma/period candidate paging and local redeployment.
- Expected result: plain comma pages backward and period forward while a Chinese candidate menu is present; boundary presses do not commit candidates or punctuation. Empty-menu, English and modified keys continue normally.
- Implementation: a small Jev Lua processor runs before scheme-specific punctuation handlers; existing native sorting locks already cover comma/period. Preserve all other processors, settings and capture state.
- Budget: focused patch and real-Rime regression, one final full preflight unless source changes, local deployment/read-only smoke; 40-minute working cap and at most five recoveries per failure class. No private input capture or model calls for tests.
- Result: baseline inspected; implementation in progress.
- Next step: test actual key events and page-boundary behavior, then commit, preflight and deploy.

### Isolated engine verification

- Current work: added the early Jev paging processor, preserved existing scheme processors, and documented comma/period behavior.
- Result: achieved. Real librime regression passed all existing cases plus paging forward/back, first/last/single-candidate boundaries, correct selection after navigation, no-menu punctuation, English passthrough and modifier-key behavior. Synthetic fixtures only; no user dictionary or model calls.
- Next step: exact-source full preflight, backup/local deployment and running-version/compiled-schema verification.
