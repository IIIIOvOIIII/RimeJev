# RimeJev / 鼠须管 Jev

Context-aware Chinese candidate recommendations for **Squirrel (鼠须管) + Rime + Wanxiang (万象)** on Apple Silicon macOS.

[中文](#中文) · [English](#english) · [LLM installation guide](LLM_INSTALL.md)

## 中文

RimeJev 在万象原生候选上增加异步语境推荐，提供 **关闭增强、云端 Jev、本地模型、云端＋本地模型** 四种模式；本地模型可选 **this-that-model 1.2、Tev 0.8B 或 Tev 4B**。基础输入不等待模型，可设置所有应用默认并为单个应用覆盖，默认关闭增强。

### 所有应用默认设置

打开“语境选词设置”，在“设置范围”中选择 **所有应用默认设置**，统一设置模式、本地模型和推荐顺序。没有单独设置的应用会自动继承，无需逐个开启。新的全局默认初始为 **关闭增强**，升级不会把此前某个应用的云端选择变成全局设置。

需要例外时选择 **当前应用单独设置**；单独设置优先，包括明确关闭增强。点击“跟随默认”可移除该应用的覆盖，重新使用全局默认。菜单也提供“当前应用：跟随所有应用默认”。超时仍按模型统一保存；安全输入和输入法自身设置不运行增强。

### 训练数据采集（0.5.1，默认关闭）

输入法菜单新增“训练数据采集与管理…”，也可从语境设置中的“训练数据…”打开。采集独立于增强模式，初始关闭且采集应用名单为空。用户自行选择保存文件夹、仅采集哪些应用或排除哪些应用、是否包含前文与模型结果，以及容量上限。

0.5.1 新增按本机日期保存、先压缩再加密；预计达到容量上限 90% 时永久清理最旧采集文件至约 80%，继续记录新输入。关闭采集不触发自动清理，手动删除仍移到废纸篓。旧格式可读取，并在下次启用写入时尝试无损压缩迁移。

记录关联真实拼音、有限同一行前文、原生候选、展示顺序、已有模型结果及实际选词。原始记录以 AES-GCM 加密保存在本机，使用独立钥匙串密钥；关闭增强时也可记录原生选择，不会额外加载或调用模型。采集失败只暂停记录。支持只读预览、移到废纸篓和本地训练集导出；数据管理会先关闭采集，完成后保持关闭。

导出数据是明文，请先审阅。无需分词器即可导出通用 records/sft；选择兼容的本地分词器后，可导出经过 token 和答案边界校验的 Tev prompt/completion 文件。不自动下载分词器、不上传数据、不启动训练。完整字段、隐私及使用边界见 [训练数据说明](docs/TRAINING_CAPTURE.md)。

### 当前行语境（0.4.2）

增强开启时，输入法读取当前输入框中、正在组合的拼音之前的同一逻辑行文字，最多使用最近 80 个完整字符。已有内容、粘贴内容、停顿后继续输入都可成为语境；窗口自动折行不切断语境，实际换行会切断。组合中已确认的汉字前缀只拼接一次。当前行为空时，也可根据拼音和真实候选调用模型，模型可以放弃推荐。

输入框不提供文字但光标位置有效时，仅回退到经过验证的连续输入记录，或无前文判断；无法确认光标位置则保留原候选。读取和模型失败都保留原生候选；移动光标、切换输入框或修改前文会使旧请求失效。读取范围、空值与 Unicode 边界均校验；首次遇到慢应用的同步接口仍可能产生延迟，后续短暂暂停文本读取。不同应用兼容性需分别验收。

云端模式发送的有限前文也可能包含输入框中已有或粘贴的文字。本地模式不发送到云端；增强关闭时停止为模型读取前文。若用户独立开启训练采集，则仅按所选应用范围和字段设置采集。安全输入和输入法自身设置不采集前文；诊断仅包含来源、长度、耗时和状态，不包含真实文本。

### 0.5.0 的候选规则

| 模型结果 | 显示与选词 |
| --- | --- |
| 命中原首选 | 原顺序不变，首选添加 `✦ Jev`、`✦ TT` 或 `✦ Tev` |
| 两模型都未命中首选 | 原首选保留；第二、三项按列表优先级放置模型推荐，其余词保持相对顺序 |
| 任一模型命中首选 | 首选标注命中的模型，第二项放另一个模型的不同推荐，第三项继续使用万象候选 |
| 两模型推荐相同词 | 合并来源标记，同一词只出现一次，余位由万象候选补齐 |
| 无结果、低可信、迟到或失败 | 继续显示原有候选，不阻碍输入 |

双模型模式同时运行 Jev 和一个本地模型。在设置中的列表选择一行，用“上移 / 下移”调整推荐优先级；到达顺序不会改变最终优先级。各模型独立超时，先返回的有效结果可先显示，选词开始后不再移动。单模型模式继续保留首选、把不同推荐放第二位。

同一推荐词不会重复出现。**空格仍选择原首选，数字 2 选择第二项**；来源文字不进入上屏内容。每页 8 个候选；全拼比较前 8 词，简拼与混合简拼最多比较 24 个真实候选；Tev 为适配训练选项数使用最多 23 词加“无匹配”。

### 安装

当前开发分支为 **0.5.1**（`feat/training-retention`）；最新正式源码版本为 **[0.5.0](https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.5.0)**，没有提供经过 Apple 公证的即装即用安装包。需要 Apple Silicon Mac、macOS 14 或更新版本、Command Line Tools、Python 3.12/3.13、uv，以及已正常运行的鼠须管 1.1.2 和万象方案。

请将 [LLM_INSTALL.md](LLM_INSTALL.md) 交给协助安装的 LLM。它包含环境检查、固定版本依赖、测试、备份、安装、系统授权、手动验收及回退步骤。完整 Xcode 不是前提。不要跳过检查直接运行安装器。

开发检查的起点：

```sh
git clone https://github.com/IIIIOvOIIII/RimeJev.git
cd RimeJev
git checkout feat/training-retention
uv sync --frozen
bash scripts/bootstrap_dev.sh
bash scripts/run_quality_gate.sh --gate local
```

本地模型在设置或输入法菜单中按应用自由切换，来源标记保持简短：

| 选项 | 推理方式 | 标记 |
| --- | --- | --- |
| this-that-model 1.2 | 本机 MLX | `✦ TT` |
| Tev 0.8B | 输入法专用本机决策进程 | `✦ Tev` |
| Tev 4B | 输入法专用本机决策进程 | `✦ Tev` |
| Jev 云端 | TypeSafe | `✦ Jev` |

只下载要使用的模型：

```sh
.venv/bin/python scripts/download_model.py
.venv/bin/python scripts/download_tev.py --model tev-0.8b
.venv/bin/python scripts/download_tev.py --model tev-4b
```

TT 权重约 3.5 GiB，Tev 0.8B 约 797 MB，Tev 4B 约 4.36 GB；Tev 还需约 167 MB 的固定运行组件下载。Tev 使用独立的回环地址和模型目录，不替换系统 Ollama，不使用云端推理。切换时旧请求失效，模型加载期间原生输入仍可用。速度与中文准确率因模型和机器而异。设置中可分别保存每个模型的超时窗口（0.3–10 秒），也可恢复默认：Jev、TT、Tev 0.8B 为 0.6 秒，Tev 4B 为 2 秒。超时保留原候选，继续输入或开始选词会作废旧结果。

### Jev 凭据与隐私

公开仓库**不包含 API Key、服务令牌、个人词库、输入记录、模型权重或本机配置**。在设置中的“Jev API 密钥”隐藏输入框填写自己的密钥并保存。密钥存入 macOS 钥匙串，保存后输入框清空，只显示“已保存”，不会回显；不会写入设置文件或命令行。已有 Vault 兼容凭据配置仍可继续使用；保存新密钥后改用钥匙串，读取失败时不会偷偷切回其他凭据来源。具体说明见 [安装指引](LLM_INSTALL.md#optional-jev-cloud-configuration)。本地模式无需 Jev 凭据。

发布源码不包含采集记录或导出的训练集。仓库中的 `evaluation/cases.jsonl` 和 `tests/fixtures/rime` 是人工构造的评估与测试样例，不来自用户输入或个人词库。加密文件、导出文件、备份和用户自选的数据目录均须留在本机，不应提交或作为 Release 附件上传。

云端模式会发送当前有限连续前文、拼音和候选给 TypeSafe；请仅按用户的明确选择，为特定应用或所有未单独配置的应用启用。本地模式不会隐式切换到云端。不要把密钥写进源码、README、设置文件或命令行参数，也不要把本地 `work/` 上传到仓库。

### 中英文提示

按 Shift 实际切换输入状态时，光标附近显示约一秒的“中文”或“英文”提示。提示独立于候选栏，不抢焦点；Shift 组合键未切换状态时不提示。

### 验证与范围

0.5.0 已通过完整构建与安装检查，覆盖默认关闭、应用范围、原生候选选择、加密存储、离线导出及现有输入行为。专用合成验收应用实测了文件夹和应用选择、加密写入、预览、人工选词标签导出及移到废纸篓；结束后采集关闭，临时测试数据已清理。Tev 指令格式导出使用合成分词器验证，未在现场运行模型训练。源码发布保留已验收的运行代码；详细证据与边界见 [VALIDATION.md](docs/VALIDATION.md)。

0.4.2 已通过 423 项后端测试、15 个实际适配器流程场景、语境解析测试及 437 组真实 Rime 探针，并完成本机安装与运行版本检查。现有设置全部保留；实际输入观察及应用兼容边界见 [VALIDATION.md](docs/VALIDATION.md)。

0.4.1 已完成默认继承、单独覆盖、恢复默认、旧配置兼容、存储重载和安全输入测试；实际设置窗口确认全局默认关闭，现有应用覆盖保留。按用户选择，本机验收没有开启全局增强，激活继承行为在隔离配置中验证。

0.4.0 通过了 396 项后端测试、437 组真实 Rime 引擎探针、原生设置/切换/密钥/语言提示测试及本机安装检查。实际设置窗口验证了双后台就绪、上下排序、跨模式保留和密钥隐藏输入；用户已确认 Shift 中英文提示。候选引擎探针使用合成词库与受控推荐，不代表真实模型准确率。公开版保留候选逻辑，移除了私有开发环境依赖，并用合成测试词库替代个人词库副本；公开版构建/测试与现场输入验收分别记录在 [VALIDATION.md](docs/VALIDATION.md)。模型仍可能判断错误，首次连接和慢响应可能保持原排序。

- [安装与恢复](LLM_INSTALL.md)
- [架构与交互](docs/ARCHITECTURE.md)
- [验证范围](docs/VALIDATION.md)
- [隐私与安全](SECURITY.md)
- [合成评估数据说明](evaluation/DATASET.md)

## English

RimeJev adds asynchronous contextual recommendations to native Wanxiang candidates. Choose **off, Jev cloud, local, or cloud + local** as the default for all applications, with per-app overrides. Select **this-that-model 1.2, Tev 0.8B, or Tev 4B** separately as the one local backend. Enhancement is off by default, and normal input never waits for a model.

### Defaults for all applications

Choose **All applications defaults** in the settings scope to configure the mode, local backend, and priority once. Apps without overrides inherit it automatically, without allowlist enrollment. The new global default starts **off**; upgrading never promotes a previously selected app's cloud mode into a global choice.

Choose **Current application settings** to create an exception. Explicit app settings, including off, take precedence. **Follow default** removes the complete app override and resumes inheritance. Timeouts remain shared per model. Secure input and the input method's own settings remain excluded.

### Training capture (0.5.1, off by default)

Open the input menu's training-data settings or the Training data button in preferences. Capture has its own off-by-default switch and initially empty application allowlist, independent of enhancement mode. Choose the local directory, included/excluded applications, context/model fields and size limit.

0.5.1 groups captures by local day and compresses before encryption. Projected 90% quota usage permanently removes the oldest capture files toward 80%, retaining new input. Capture off performs no automatic cleanup; manual deletion still uses Trash. Legacy files remain readable and may be compacted without changing records on the next enabled write.

Records link actual pinyin, bounded current-line context, native candidates, displayed order, existing model results and observed human choices. AES-GCM encrypts local captures with a separate Keychain key. Capture-only mode records native choices without loading/calling models. Storage failures pause capture while normal input remains available. Preview, recoverable deletion and local export first disable capture and leave it off afterwards.

Exports are plaintext and need review. Generic records/sft exports require no tokenizer; a compatible local tokenizer enables validated Tev prompt/completion exports. No tokenizer download, data upload or training is automatic. See [the training-data guide](docs/TRAINING_CAPTURE.md) for fields and boundaries.

### Current-line context (0.4.2)

When enhancement is enabled, the IME reads up to the latest 80 complete characters in the same logical line before the composition. Existing, pasted and paused input can supply context. Soft wrapping does not split context; actual newlines do. Confirmed composition prefixes are appended once. Empty lines still permit a model decision using pinyin and genuine candidates, including abstention.

Unavailable host text with a valid caret anchor falls back only to verified recent commits or an empty context. Unavailable caret positions retain native candidates. Cursor, input-client or preceding-text changes invalidate old requests. Range/Unicode checks reject malformed host responses. Native candidates remain available on read/model failure. A slow synchronous host API can delay its first read; subsequent reads temporarily back off. Application compatibility requires separate live verification.

In cloud mode, the bounded prefix may include existing or pasted text from the input field. Local mode never sends it to cloud. Enhancement off stops model-context reads; independently enabled training capture follows its selected application scope and field settings. Secure input and the IME's own settings remain excluded. Diagnostics contain only source, length, duration and status, never actual text.

### Candidate behavior in 0.5.0

| Model result | Display and selection |
| --- | --- |
| Selects the original first candidate | Keep the complete order; label it `✦ Jev`, `✦ TT`, or `✦ Tev` |
| Neither model selects the first word | Preserve it; put distinct recommendations in slots 2/3 using the user-ordered list |
| Either model selects the first word | Label that first word; put the other distinct recommendation second, followed by native candidates |
| Both select the same word | Merge source badges, keep one instance, and fill remaining positions with native candidates |
| No match, low confidence, late response, or failure | Keep native candidates available and unchanged |

Use the list’s Up/Down buttons to choose cloud/local priority. One cloud and one local backend run concurrently with independent deadlines. Early valid responses can appear first; the final order follows user priority rather than response arrival. Selection freezes movement. Single-model mode preserves the original first choice and puts a different recommendation second.

The recommendation is removed from its previous position, so it is not duplicated. **Space still selects the original first candidate; 2 selects the second candidate.** Labels are display-only. The panel retains eight candidates per page. Full pinyin uses an eight-candidate decision window; abbreviated or mixed pinyin can use up to 24 genuine candidates (Tev uses up to 23 plus `none` to stay within its trained option range).

### Installation

The current development branch is **0.5.1** (`feat/training-retention`); the latest formal release is the **[0.5.0 source release](https://github.com/IIIIOvOIIII/RimeJev/releases/tag/v0.5.0)**; an Apple-notarized installer is not provided. Requirements: Apple Silicon, macOS 14+, Command Line Tools, Python 3.12/3.13, uv, and a working Squirrel 1.1.2 installation with Wanxiang. Full Xcode is not required for this build path. The commands here select the 0.5.1 development branch; record its exact commit for installation. Use the `v0.5.0` tag and its own guide when installing that release.

Give [LLM_INSTALL.md](LLM_INSTALL.md) to the LLM assisting with installation. Follow its preflight, backup, build, consent, smoke-test, manual typing, and rollback steps. The commands in the Chinese section are the same commands for English-language installations. Model weights are optional for cloud/off mode and are downloaded separately for local mode. Select TT, Tev 0.8B, or Tev 4B from settings for each application’s local or dual mode. Labels are exactly `✦ TT`, `✦ Tev`, and `✦ Jev`, regardless of recommendation position. Tev uses a pinned local runtime on a dedicated loopback port; it does not replace the system Ollama service or enable cloud inference. Settings expose a separate 0.3–10 second timeout for every model, with restore-default controls. Defaults are 0.6s for Jev/TT/Tev 0.8B and 2s for Tev 4B. Time includes debounce and sampling; continuing input or selection invalidates old results.

### Credentials and data

No real credentials or personal input data are distributed. Enter the Jev API key in the secure settings field. It is stored in macOS Keychain, never redisplayed, and sent to the child runtime through a private one-shot pipe rather than arguments, environment, or settings. Existing Vault-compatible metadata remains supported; saving a direct key selects Keychain explicitly, with no fallback on credential failure. There is **no shared or preconfigured cloud account**. See the exact [credential contract](LLM_INSTALL.md#optional-jev-cloud-configuration). A local-only installation does not need cloud credentials.

Release sources contain no collected records or exported training datasets. `evaluation/cases.jsonl` and `tests/fixtures/rime` contain hand-authored evaluation/test fixtures, not user input or personal dictionaries. Keep encrypted captures, exports, backups and user-selected data directories local; never commit them or upload them as release assets.

Cloud mode sends a bounded preceding context, the current pinyin, and candidates to TypeSafe. Enable it only through the user’s explicit choice, either for specific apps or as the default for unconfigured apps. Local mode never silently falls back to cloud. Keep keys out of source files, settings, documentation, process arguments, and Git history. Runtime directories, dictionaries, weights, logs, and local settings stay outside version control.

### Language feedback

An actual Shift-triggered language change shows a one-second Chinese/English indicator near the caret. It is separate from the candidate panel and never takes focus; unchanged Shift combinations do not show it.

### Validation and limitations

0.5.0 passed the full build and installation checks covering default-off behavior, application scope, native selection, encrypted storage, offline export and existing input behavior. A dedicated synthetic validation app exercised folder/app selection, encrypted writes, preview, human-label export and recoverable deletion. Capture was left off and temporary test data was cleaned up. Tev instruction exports were validated with synthetic tokenizers; no live model training was performed. This source release retains the verified runtime code. See [VALIDATION.md](docs/VALIDATION.md) for evidence and limits.

0.4.2 passed 423 backend tests, 15 actual-adapter scenarios, context-parser tests and 437 real-Rime probes, plus local installation and running-version checks. All existing settings were preserved. See [VALIDATION.md](docs/VALIDATION.md) for live typing observations and application-specific boundaries.

0.4.1 validates default inheritance, complete overrides, reset, legacy compatibility, reload, and secure-input eligibility. The installed UI confirms the global default is off and existing app overrides remain intact. Active global profiles were tested in isolated settings; the live default stayed off at the user’s request.

Version 0.4.0 passed 396 backend tests, 437 real-Rime probes, native settings/switching/credential/indicator tests, and installation checks. The installed settings window verified both backends ready, Up/Down ordering, persistence across modes, and masked key input. The user confirmed actual Shift language feedback. Controlled engine responses and synthetic dictionaries validate placement, not model accuracy. Public packaging removes private-machine assumptions and supplies synthetic Rime fixtures. See [the validation report](docs/VALIDATION.md) for the public release checks and the distinction between engine tests, model quality, and live typing acceptance.

This remains an experimental input-method integration. Recommendations can be wrong, and slow responses intentionally leave native ordering unchanged. Do not infer support for every macOS application from one successful host test.

## License and upstream projects / 许可与上游

Distributed under **GNU GPL v3**; see [LICENSE](LICENSE). Squirrel's upstream license and copyright notices are retained. The librime header retains its BSD notice. Downloaded SDKs, model weights, and frameworks retain their own licenses and are not redistributed in this source repository. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

- [Squirrel / 鼠须管](https://github.com/rime/squirrel)
- [librime](https://github.com/rime/librime)
- [Wanxiang / 万象](https://github.com/amzxyz/rime_wanxiang)
- [FLock this-that-model SDK](https://github.com/FLock-io/this-that-model)
- [TypeSafe / Jev](https://typesafe.ai/)

## Tev references / Tev 参考

- [Together Tev1](https://github.com/togethercomputer/tev1)
- [Official Tev model distribution](https://ollama.com/library/tev1)
- [Local decision API](https://docs.ollama.com/api/systemone)

Tev model probabilities are model preferences, not calibrated correctness. Public English benchmark scores do not establish Chinese input-method accuracy.
