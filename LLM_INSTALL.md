# LLM_INSTALL — RimeJev 0.4.0

This is the dedicated installation contract for an LLM helping a user. 中文：这是提供给安装助手的独立指引；先检查、备份、验证，再安装，不能把构建成功当成真实输入验收。

## Scope and operating rules

- Work on the user's Mac. This native input method cannot be built or validated as a macOS IME in a Linux container.
- Proceed within the user's existing installation authorization; do not repeatedly ask for the same permission. Explain concrete missing prerequisites when blocked.
- Preserve all existing input methods, user dictionaries, settings, text, and unrelated files. Never overwrite `~/Library/Rime` with a backup. Never reset macOS input-source preferences or disable SIP, Gatekeeper, TLS verification, or system permissions to make a test pass.
- Use a dedicated empty test document. Never type test strings into a message composer that could send them, or replace an existing user document.
- Do not ask the user to paste an API key into chat. Do not put a secret in command arguments, a settings file, an environment example, logs, the clipboard, or a commit.
- Local mode must never fall back to cloud. Model enhancement starts **off**, and per-app cloud enablement requires the user's choice.
- Do not run `scripts/evaluate.py` as an installation test. It is an optional legacy experiment requiring separate prepared data and an explicit call budget; it does not measure the current second-slot UI policy.
- Do not change probability thresholds, response deadlines, or candidate words merely to produce a successful-looking screenshot.

## 1. Inspect prerequisites

Run read-only checks for macOS version, `uname -m`, CLT (`xcrun --find swiftc`), Python 3.12/3.13, uv, free disk space, and current repository status. Support target: **Apple Silicon / arm64, macOS 14+**. The tested development machine was an M4 with 24 GB RAM; this is not a minimum-memory guarantee.

Required existing input installation:

- `/Library/Input Methods/Squirrel.app`, version 1.1.2, with `librime.1.dylib`, Sparkle, and compiled resources.
- A working Wanxiang configuration in `~/Library/Rime`, including `wanxiang.schema.yaml`.
- A source checkout in a persistent directory. The installed IME continues using that checkout's `.venv` and model path, so do not install from a disposable download directory.

If these are missing, stop the dependent step and explain what is missing. Use official Squirrel/Wanxiang setup instructions; do not silently install another user's dictionary or overwrite their scheme. If the upstream binary version differs, establish compatibility before using its frameworks. The native build reuses installed frameworks; it does not download an unofficial app bundle.

## 2. Obtain and prepare the source

```sh
git clone https://github.com/IIIIOvOIIII/RimeJev.git
cd RimeJev
git checkout feat/dual-model-settings
git rev-parse HEAD  # Record and retain this exact reviewed revision for installation.
uv sync --frozen
bash scripts/bootstrap_dev.sh
```

If the checkout already exists, inspect it first, preserve local changes, and explicitly select the requested release. Do not use a floating `git pull` as an install step.

The bootstrap uses upstream Squirrel commit `876adebaf2f612951dcdca8a591de65401222b9a` under ignored `work/upstream/squirrel`. It must not force-reset an existing different checkout. The native builder pins librime headers to `a251145d3aafa33871824a40bbec04c966bd8b56` and Sparkle source metadata to `41847a58cdef7506b257591fcca6f9495df591d4`.

All temporary files, downloaded sources, binaries, model weights, and local test evidence belong under ignored `work/` or `artifacts/`. No personal dictionary is needed by the public regression suite: it uses synthetic fixtures in `tests/fixtures/rime`.

## 3. Back up before installation

The original app and data remain separate from RimeJev. Preserve a baseline without overwriting existing backups:

```sh
mkdir -p work/backups/pre-install
if [ ! -e work/backups/pre-install/Squirrel.app ]; then
  ditto '/Library/Input Methods/Squirrel.app' work/backups/pre-install/Squirrel.app
fi
if [ ! -e work/backups/pre-install/Rime ]; then
  ditto "$HOME/Library/Rime" work/backups/pre-install/Rime
fi
```

For an update, also preserve existing `~/Library/Input Methods/Rime-Jev.app`, `~/Library/Rime-Jev`, and the non-secret settings under `~/Library/Application Support/Rime-Jev` in a new timestamped directory under `work/backups`. The installer backs up its previous app, but does not replace a complete user-data backup. Never upload these backups to GitHub.

Finish or cancel any active composition before restarting the input method.

## 4. Prepare the selected model

### Local this-that-model 1.2

Download only if local mode is requested and the verified weights are not already available:

```sh
.venv/bin/python scripts/download_model.py
```

The script pins `flock-io/this-that-model-1.2` revision `c4d1c30b8d512d278726de439b8cc81fccc70c8f` and verifies Git/LFS hashes. Download size is about 3.5 GiB; leave additional disk and RAM headroom. Existing valid custom model paths should be preserved. Inference is offline after installation; download itself uses the network.

Do not fetch model weights for an off/cloud-only installation. An absent local model must disable only enhancement, not native input.

### Local Tev 0.8B / 4B

Only download explicitly requested variants:

```sh
.venv/bin/python scripts/download_tev.py --model tev-0.8b
.venv/bin/python scripts/download_tev.py --model tev-4b
```

The installer uses official Ollama 0.40.3, verifies its archive SHA-256, and verifies each model's pinned manifest digest. The private runtime lives under the checkout's ignored `work/runtime`, model blobs under ignored `work/models/ollama`, and the API binds only `127.0.0.1:11435`. It must not alter the user's system Ollama service on port 11434. Cloud features are disabled. Never repoint the provider to a remote endpoint or broaden the bind address to make setup work.

Plan for about 797 MB for Tev 0.8B, 4.36 GB for Tev 4B, plus the runtime archive/extraction and free-disk headroom. There is no automatic download during typing. A missing model/runtime must only disable enhancement. Settings and the input menu offer independent TT, Tev 0.8B, and Tev 4B choices; the two Tev sizes use the same `✦ Tev` badge but distinct request identities.

Tev accepts at most 23 candidate options plus `none`. Do not omit the abstention option to make 24 words fit. Preserve probability/margin checks and honor each model’s configured deadline. Default timeouts are 0.6s for TT/Jev/Tev 0.8B and 2s for Tev 4B; settings allow 0.3–10s per model. Time includes input debounce and candidate sampling, so the runtime receives only the remaining budget. Verify both variants with small synthetic requests after loading, record cold versus warm latency, and do not substitute a regular Qwen model for Tev if a download fails.

### Optional Jev cloud configuration

New users can enter the Jev API key directly in **鼠须管 Jev 设置 → Jev API 密钥**. The field is a secure password control. Saving stores an exact generic-password item in macOS Keychain (service `RimeJev`, account `Jev API`), clears the input field, and shows saved status without redisplaying the key. Let the user enter the real key; do not ask for it in chat, retrieve it for screenshots, or put it in commands. The caller performs Keychain work off the key-handling/UI thread. The native process sends the key to Jev's child once through stdin, with bounded JSON framing and no key in argv/env/settings. Missing or rejected credentials leave native input available. Deleting the saved key disables direct credentials rather than silently returning to Vault.

Four per-app enhancement modes are available: off, cloud, local, and cloud + local. A separate selector chooses TT/Tev 0.8B/Tev 4B. Dual mode starts exactly one local backend plus Jev, with the two-row Up/Down list determining recommendation priority. Legacy per-app `tev-0.8b` and `tev-4b` settings migrate in place to the equivalent local-only behavior. Never enable cloud for a previously local-only app during migration. Timeouts remain independent per model.

Existing installations may retain the legacy credential service path below. Saving a direct key explicitly selects Keychain; a Keychain error must not fall back to the service. No secret migration is performed automatically.

The repository includes a **Vault-compatible ref-service adapter**, not a shared account and not a claim that unmodified HashiCorp Vault endpoints match this API. A cloud setup needs a user-operated, authorized credential service with this contract:

1. An absolute-path executable helper returns a short-lived service bearer on stdout. No arguments contain credentials. The runtime captures stdout without logging it.
2. The runtime makes verified HTTPS `GET /api/v1/secrets/<URL-encoded-ref>`, with `Authorization: Bearer <helper output>`.
3. The response is a JSON object with `ref` equal to the requested ref and a nonempty string `value` containing the TypeSafe API key. The key remains in runtime memory.
4. Redirects are rejected. Authentication/helper/service failures stop enhancement without plaintext fallback or a switch from local to cloud.

After installation, the existing settings file is `~/Library/Application Support/Rime-Jev/settings.json`. Preserve every existing field and per-app choice. Add only these **non-secret metadata** fields using values supplied by the user:

```json
{
  "vaultURL": "https://vault.example.invalid",
  "vaultTokenHelper": "/absolute/path/to/authorized-token-helper",
  "vaultRef": "typesafe_api_key"
}
```

The example is deliberately unusable until configured. Do not invent a service address, account, ref, or helper. Do not implement a helper that embeds a bearer or API key in source. Missing credentials are a supported fallback case; local/off mode can still be installed.

The native process passes the metadata as `RIME_JEV_VAULT_URL` and `RIME_JEV_VAULT_TOKEN_HELPER` to its child runtime. When launching the runtime manually, those same environment variables carry **metadata only**; `--vault-ref` carries the ref name, never its value. Cloud content consists of the bounded current context, pinyin, and candidates. The user must choose the applications in which this is acceptable.

Restart only RimeJev and its runtime after metadata changes. Never print keys to demonstrate that authentication worked. If testing real inference is authorized, use a small fixed synthetic sentence and report only status/choice/latency; do not run a bulk evaluation automatically.

## 5. Run checks before changing the installed app

```sh
bash scripts/run_quality_gate.sh --gate deploy-preflight
```

This requires a clean tracked source tree and executes backend tests with at least 85% line coverage, Swift coordinator tests with at least 80% line coverage, context/badge tests, syntax checks, an arm64 app build, and real-Rime fixture tests. It writes logs and a summary under `artifacts/quality-gate` and an exact source/binary receipt to `work/evidence/preflight.json`.

Never fabricate a passing receipt, lower thresholds to get a pass, or reuse a receipt for different source or binaries. Resolve failures before installation. Network/model requests are not part of these regression tests.

If you make an authorized source change, review and commit it locally before re-running preflight. Do not automatically push local adaptations or private settings.

## 6. Install the validated build

```sh
bash scripts/deploy.sh --validated
bash scripts/run_quality_gate.sh --gate post-deploy-readonly
```

The installer verifies the receipt, stops this project's runtimes, backs up its existing app, prepares a separate `~/Library/Rime-Jev`, copies the app into `~/Library/Input Methods/Rime-Jev.app`, compiles its scheme, and registers/enables its own bundle. It never replaces the original Squirrel app or original Rime data. On update it refreshes `projectRoot` for the selected checkout while preserving existing per-app settings and model/credential metadata.

If macOS requests input-method permission, let the user grant the displayed permission through the normal system UI. The requesting app must be **鼠须管 Jev**, not a generic `swift` helper. Do not edit permission databases or source lists to bypass consent. If registration takes time, check actual state before a bounded re-registration of the same app; do not repeatedly reinstall or create another bundle ID.

The post-install check verifies bundle name/ID, signature, binary receipt, deployed Lua/source equality, and input-source availability. Original input methods may coexist; removing them is not part of this guide.

## 7. Verify actual typing separately

Use a dedicated empty input window and select **鼠须管 Jev**. First verify basic pinyin/selection with enhancement off. Then enable the user-selected backend for that test application using the input method's own menu. Local loading and first cloud connection may be slow; the native list must stay usable.

Check model switching and each model’s timeout field: save, close/reopen, switch to another model, return, and restore the default. Existing per-application choices must stay intact.

Check these cases:

- If a timely confident model decision matches the original first word, the order stays unchanged and that word gets `✦ Jev` or `✦ TT` / `✦ Tev`.
- In dual mode, if neither model matches first, slots 2/3 follow the configured order. If either matches first, badge first and put the other distinct result second. The next unused native word follows. Same-word recommendations merge source labels without duplication. Missing results leave native fillers. Single-model behavior remains first-preserved/second-recommended.
- Space selects the original first word. `2` selects the displayed second word. `3` selects the displayed third word. Badges never appear in committed text.
- Move the priority rows both ways and verify persistence; switch all four modes and all three local variants. Only one local process may be active alongside Jev.
- Press Shift to change Chinese/English, checking the short separate indicator and unchanged focus. Shift combinations that do not change Rime mode must not display a false notification.
- Turning enhancement off restores native order. No result, timeout, missing credentials, and model loading must not block native selection.

Suggested synthetic context: type “我现在又想”, then `sj`. A model may suggest “睡觉”, but native frequencies and model decisions vary. Never force this word or reduce the threshold merely to pass acceptance. The deterministic test suite proves placement independently of model choice.

If automation inserts raw Latin letters while the IME receives zero events, record the automation limitation and request one manual check in a working host. Do not interpret that as a successful UI test or repeatedly reinstall.

The installed executable accepts `--status`; it asynchronously writes `~/Library/Rime-Jev/jev-status.json`. Verify its timestamp before reading. Diagnostics contain counts, lengths, and reasons, not typed text. Do not add content logging to troubleshoot a private document.

## 8. Rollback and completion report

```sh
bash scripts/deploy.sh --rollback
```

Rollback disables this project's input source and selects the original Squirrel source, retaining RimeJev data for recovery. Verify the original source is available first. Do not delete later-learned user data or overwrite it with an old backup. Destructive cleanup is separate from rollback.

Report the exact source revision/version, build and install checks, actual typing result, remaining limitations, and backup location. Distinguish source tests, installation checks, model choice, and user-visible acceptance. Do not claim universal application compatibility or a production-signed installer.
