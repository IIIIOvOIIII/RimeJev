# RimeJev / 鼠须管 Jev

Context-aware Chinese candidate recommendations for **Squirrel (鼠须管) + Rime + Wanxiang (万象)** on Apple Silicon macOS.

[中文](#中文) · [English](#english) · [LLM installation guide](LLM_INSTALL.md)

## 中文

RimeJev 在万象原生候选上增加异步语境推荐，提供 **关闭增强、云端 Jev、本地模型、云端＋本地模型** 四种模式；本地模型可选 **this-that-model 1.2、Tev 0.8B 或 Tev 4B**。基础输入不等待模型，按应用启用增强，默认关闭。

### 所有应用默认设置

打开“语境选词设置”，在“设置范围”中选择 **所有应用默认设置**，统一设置模式、本地模型和推荐顺序。没有单独设置的应用会自动继承，无需逐个开启。新的全局默认初始为 **关闭增强**，升级不会把此前某个应用的云端选择变成全局设置。

需要例外时选择 **当前应用单独设置**；单独设置优先，包括明确关闭增强。点击“跟随默认”可移除该应用的覆盖，重新使用全局默认。菜单也提供“当前应用：跟随所有应用默认”。超时仍按模型统一保存；安全输入和输入法自身设置不运行增强。

### 0.4.1 的候选规则

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

这是 **0.4.1 源码开发版**，没有提供经过 Apple 公证的即装即用安装包。需要 Apple Silicon Mac、macOS 14 或更新版本、Command Line Tools、Python 3.12/3.13、uv，以及已正常运行的鼠须管 1.1.2 和万象方案。

请将 [LLM_INSTALL.md](LLM_INSTALL.md) 交给协助安装的 LLM。它包含环境检查、固定版本依赖、测试、备份、安装、系统授权、手动验收及回退步骤。完整 Xcode 不是前提。不要跳过检查直接运行安装器。

开发检查的起点：

```sh
git clone https://github.com/IIIIOvOIIII/RimeJev.git
cd RimeJev
git checkout feat/global-default-settings
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

云端模式会发送当前有限连续前文、拼音和候选给 TypeSafe；请仅在用户明确选择的应用启用。本地模式不会隐式切换到云端。不要把密钥写进源码、README、设置文件或命令行参数，也不要把本地 `work/` 上传到仓库。

### 中英文提示

按 Shift 实际切换输入状态时，光标附近显示约一秒的“中文”或“英文”提示。提示独立于候选栏，不抢焦点；Shift 组合键未切换状态时不提示。

### 验证与范围

0.4.0 通过了 396 项后端测试、437 组真实 Rime 引擎探针、原生设置/切换/密钥/语言提示测试及本机安装检查。实际设置窗口验证了双后台就绪、上下排序、跨模式保留和密钥隐藏输入；用户已确认 Shift 中英文提示。候选引擎探针使用合成词库与受控推荐，不代表真实模型准确率。公开版保留候选逻辑，移除了私有开发环境依赖，并用合成测试词库替代个人词库副本；公开版构建/测试与现场输入验收分别记录在 [VALIDATION.md](docs/VALIDATION.md)。模型仍可能判断错误，首次连接和慢响应可能保持原排序。

- [安装与恢复](LLM_INSTALL.md)
- [架构与交互](docs/ARCHITECTURE.md)
- [验证范围](docs/VALIDATION.md)
- [隐私与安全](SECURITY.md)
- [合成评估数据说明](evaluation/DATASET.md)

## English

RimeJev adds asynchronous contextual recommendations to native Wanxiang candidates. Choose **off, Jev cloud, local, or cloud + local** per application. Select **this-that-model 1.2, Tev 0.8B, or Tev 4B** separately as the one local backend. Enhancement is off by default, and normal input never waits for a model.

### Defaults for all applications

Choose **All applications defaults** in the settings scope to configure the mode, local backend, and priority once. Apps without overrides inherit it automatically, without allowlist enrollment. The new global default starts **off**; upgrading never promotes a previously selected app's cloud mode into a global choice.

Choose **Current application settings** to create an exception. Explicit app settings, including off, take precedence. **Follow default** removes the complete app override and resumes inheritance. Timeouts remain shared per model. Secure input and the input method's own settings remain excluded.

### Candidate behavior in 0.4.1

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

This is a **source release**, not an Apple-notarized installer. Requirements: Apple Silicon, macOS 14+, Command Line Tools, Python 3.12/3.13, uv, and a working Squirrel 1.1.2 installation with Wanxiang. Full Xcode is not required for this build path.

Give [LLM_INSTALL.md](LLM_INSTALL.md) to the LLM assisting with installation. Follow its preflight, backup, build, consent, smoke-test, manual typing, and rollback steps. The commands in the Chinese section are the same commands for English-language installations. Model weights are optional for cloud/off mode and are downloaded separately for local mode. Select TT, Tev 0.8B, or Tev 4B from settings for each application’s local or dual mode. Labels are exactly `✦ TT`, `✦ Tev`, and `✦ Jev`, regardless of recommendation position. Tev uses a pinned local runtime on a dedicated loopback port; it does not replace the system Ollama service or enable cloud inference. Settings expose a separate 0.3–10 second timeout for every model, with restore-default controls. Defaults are 0.6s for Jev/TT/Tev 0.8B and 2s for Tev 4B. Time includes debounce and sampling; continuing input or selection invalidates old results.

### Credentials and data

No real credentials or personal input data are distributed. Enter the Jev API key in the secure settings field. It is stored in macOS Keychain, never redisplayed, and sent to the child runtime through a private one-shot pipe rather than arguments, environment, or settings. Existing Vault-compatible metadata remains supported; saving a direct key selects Keychain explicitly, with no fallback on credential failure. There is **no shared or preconfigured cloud account**. See the exact [credential contract](LLM_INSTALL.md#optional-jev-cloud-configuration). A local-only installation does not need cloud credentials.

Cloud mode sends a bounded preceding context, the current pinyin, and candidates to TypeSafe. Enable it only for applications the user chooses. Local mode never silently falls back to cloud. Keep keys out of source files, settings, documentation, process arguments, and Git history. Runtime directories, dictionaries, weights, logs, and local settings stay outside version control.

### Language feedback

An actual Shift-triggered language change shows a one-second Chinese/English indicator near the caret. It is separate from the candidate panel and never takes focus; unchanged Shift combinations do not show it.

### Validation and limitations

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
