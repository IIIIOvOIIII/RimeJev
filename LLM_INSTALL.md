# LLM_INSTALL — RimeJev 0.2.4

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

Run read-only checks for macOS version, `uname -m`, CLT (`xcrun --find swiftc`), Python 3.12/3.13, uv, free disk space, and current repository status. Support target: **Apple Silicon / arm64, macOS 13+**. The tested development machine was an M4 with 24 GB RAM; this is not a minimum-memory guarantee.

Required existing input installation:

- `/Library/Input Methods/Squirrel.app`, version 1.1.2, with `librime.1.dylib`, Sparkle, and compiled resources.
- A working Wanxiang configuration in `~/Library/Rime`, including `wanxiang.schema.yaml`.
- A source checkout in a persistent directory. The installed IME continues using that checkout's `.venv` and model path, so do not install from a disposable download directory.

If these are missing, stop the dependent step and explain what is missing. Use official Squirrel/Wanxiang setup instructions; do not silently install another user's dictionary or overwrite their scheme. If the upstream binary version differs, establish compatibility before using its frameworks. The native build reuses installed frameworks; it does not download an unofficial app bundle.

## 2. Obtain and prepare the source

```sh
git clone https://github.com/IIIIOvOIIII/RimeJev.git
cd RimeJev
git checkout v0.2.4
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

### Optional Jev cloud configuration

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

Check these cases:

- If a timely confident model decision matches the original first word, the order stays unchanged and that word gets `✦ Jev` or `✦ 本地`.
- If it selects another genuine word, the original first word stays first; the recommendation appears second with `✦ Jev 推荐` or `✦ 本地模型推荐` and is removed from its old position.
- Space selects the original first word. `2` selects the displayed second word. `3` selects the displayed third word. Badges never appear in committed text.
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
