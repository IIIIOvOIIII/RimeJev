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

- Current work: completed global defaults and per-application overrides, installed source `2b9ab93fa8349e6c5bb13b3e3266ebeb1f08e04a`.
- Result: full preflight and installed smoke passed. Isolated production-Settings tests passed all eight logic groups and six loader scenarios. Actual UI shows global-off, current-app override and follow-default controls. Existing app modes/local choices/order/timeouts/credential metadata were compared with the pre-install snapshot and are unchanged.
- User preference honored: no global model was enabled during installation or UI verification. The settings window was returned to global defaults, still off. Live model-quality testing is unnecessary for this settings-only feature.
- Next: the user can select one global default whenever desired; unconfigured apps inherit automatically. The feature branch and bilingual instructions are synchronized; no required work remains for this request.
