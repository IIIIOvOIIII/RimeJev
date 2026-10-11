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
