# RimeJev / 鼠须管 Jev

Context-aware Chinese candidate recommendations for **Squirrel (鼠须管) + Rime + Wanxiang (万象)** on Apple Silicon macOS.

[中文](#中文) · [English](#english) · [LLM installation guide](LLM_INSTALL.md)

## 中文

RimeJev 在万象原生候选上增加异步语境推荐，可选择 **Jev 云端**或 **this-that-model 1.2 本地模型**。基础输入不等待模型，按应用启用增强，默认关闭。

### 0.2.4 的候选规则

| 模型结果 | 显示与选词 |
| --- | --- |
| 命中原首选 | 原顺序不变，首选添加 `✦ Jev` 或 `✦ 本地` |
| 命中其他词 | 保留原首选，将推荐移至第二位，添加 `✦ Jev 推荐` 或 `✦ 本地模型推荐`；其余候选保持相对顺序 |
| 无结果、低可信、迟到或失败 | 继续显示原有候选，不阻碍输入 |

同一推荐词不会重复出现。**空格仍选择原首选，数字 2 选择第二项**；来源文字不进入上屏内容。每页 8 个候选；全拼比较前 8 词，简拼与混合简拼最多比较 24 个真实候选。

### 安装

这是 **0.2.4 源码发布**，没有提供经过 Apple 公证的即装即用安装包。需要 Apple Silicon Mac、macOS 13 或更新版本、Command Line Tools、Python 3.12/3.13、uv，以及已正常运行的鼠须管 1.1.2 和万象方案。

请将 [LLM_INSTALL.md](LLM_INSTALL.md) 交给协助安装的 LLM。它包含环境检查、固定版本依赖、测试、备份、安装、系统授权、手动验收及回退步骤。完整 Xcode 不是前提。不要跳过检查直接运行安装器。

开发检查的起点：

```sh
git clone https://github.com/IIIIOvOIIII/RimeJev.git
cd RimeJev
uv sync --frozen
bash scripts/bootstrap_dev.sh
bash scripts/run_quality_gate.sh --gate local
```

本地模式还需显式下载固定版本的公开权重：

```sh
.venv/bin/python scripts/download_model.py
```

下载约 3.5 GiB；历史测试在 Apple M4 / 24 GB 机器上观察到约 4 GB 模型内存峰值。这不是所有机器的性能保证。模型未就绪时原生输入仍可用。

### Jev 凭据与隐私

公开仓库**不包含 API Key、服务令牌、个人词库、输入记录、模型权重或本机配置**。Jev 默认使用可配置的 Vault 兼容凭据适配器，需要用户自己的 HTTPS 凭据服务、令牌辅助程序和 ref；仓库没有预置可用的服务地址或账号。具体协议见 [安装指引](LLM_INSTALL.md#optional-jev-cloud-configuration)。本地模式无需 Jev 凭据。

云端模式会发送当前有限连续前文、拼音和候选给 TypeSafe；请仅在用户明确选择的应用启用。本地模式不会隐式切换到云端。不要把密钥写进源码、README、设置文件或命令行参数，也不要把本地 `work/` 上传到仓库。

### 验证与范围

0.2.4 的原始开发版本通过了 96 项后端测试、84 组真实 Rime 引擎回归及本机安装检查，用户确认了第二位推荐和数字 2 上屏。公开版保留候选逻辑，移除了私有开发环境依赖，并用合成测试词库替代个人词库副本；公开版构建/测试与现场输入验收分别记录在 [VALIDATION.md](docs/VALIDATION.md)。模型仍可能判断错误，首次连接和慢响应可能保持原排序。

- [安装与恢复](LLM_INSTALL.md)
- [架构与交互](docs/ARCHITECTURE.md)
- [验证范围](docs/VALIDATION.md)
- [隐私与安全](SECURITY.md)
- [合成评估数据说明](evaluation/DATASET.md)

## English

RimeJev adds asynchronous contextual recommendations to native Wanxiang candidates. Choose **Jev cloud** or the local **this-that-model 1.2** backend per application. Enhancement is off by default, and normal input never waits for a model.

### Candidate behavior in 0.2.4

| Model result | Display and selection |
| --- | --- |
| Selects the original first candidate | Keep the complete order; label it `✦ Jev` or `✦ 本地` |
| Selects another candidate | Preserve the original first choice; move the recommendation to slot 2 with `✦ Jev 推荐` or `✦ 本地模型推荐`; preserve the relative order of the remaining candidates |
| No match, low confidence, late response, or failure | Keep native candidates available and unchanged |

The recommendation is removed from its previous position, so it is not duplicated. **Space still selects the original first candidate; 2 selects the second candidate.** Labels are display-only. The panel retains eight candidates per page. Full pinyin uses an eight-candidate decision window; abbreviated or mixed pinyin can use up to 24 genuine candidates.

### Installation

This is a **source release**, not an Apple-notarized installer. Requirements: Apple Silicon, macOS 13+, Command Line Tools, Python 3.12/3.13, uv, and a working Squirrel 1.1.2 installation with Wanxiang. Full Xcode is not required for this build path.

Give [LLM_INSTALL.md](LLM_INSTALL.md) to the LLM assisting with installation. Follow its preflight, backup, build, consent, smoke-test, manual typing, and rollback steps. The commands in the Chinese section are the same commands for English-language installations. Model weights are optional for cloud/off mode and are downloaded separately for local mode.

### Credentials and data

No real credentials or personal input data are distributed. The optional cloud adapter reads one explicitly configured ref from a user-operated Vault-compatible HTTPS service via a token helper. There is **no shared or preconfigured cloud account**. See the exact [credential contract](LLM_INSTALL.md#optional-jev-cloud-configuration). A local-only installation does not need cloud credentials.

Cloud mode sends a bounded preceding context, the current pinyin, and candidates to TypeSafe. Enable it only for applications the user chooses. Local mode never silently falls back to cloud. Keep keys out of source files, settings, documentation, process arguments, and Git history. Runtime directories, dictionaries, weights, logs, and local settings stay outside version control.

### Validation and limitations

The development version passed 96 backend tests, 84 real-Rime regression probes, and installation checks; the user confirmed second-slot recommendations and digit-2 submission. Public packaging removes private-machine assumptions and supplies synthetic Rime fixtures. See [the validation report](docs/VALIDATION.md) for the public release checks and the distinction between engine tests, model quality, and live typing acceptance.

This remains an experimental input-method integration. Recommendations can be wrong, and slow responses intentionally leave native ordering unchanged. Do not infer support for every macOS application from one successful host test.

## License and upstream projects / 许可与上游

Distributed under **GNU GPL v3**; see [LICENSE](LICENSE). Squirrel's upstream license and copyright notices are retained. The librime header retains its BSD notice. Downloaded SDKs, model weights, and frameworks retain their own licenses and are not redistributed in this source repository. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

- [Squirrel / 鼠须管](https://github.com/rime/squirrel)
- [librime](https://github.com/rime/librime)
- [Wanxiang / 万象](https://github.com/amzxyz/rime_wanxiang)
- [FLock this-that-model SDK](https://github.com/FLock-io/this-that-model)
- [TypeSafe / Jev](https://typesafe.ai/)
