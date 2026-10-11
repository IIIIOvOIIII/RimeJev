# Training capture / 训练数据采集

0.5.0 introduces optional, local encrypted collection. Collection starts **off**, independently of cloud/local enhancement. Upgrades never infer consent from an enhancement profile. The initial selected-app list is empty.

## 使用

打开输入法菜单“训练数据采集与管理…”或设置中的“训练数据…”。选择保存文件夹及采集应用，按需选择上下文、模型结果和保存上限，最后明确启用并保存。默认路径为 `~/Library/Application Support/Rime-Jev/TrainingData`，默认上限 1 GiB。范围可以是仅选中应用，或所有应用减去排除列表。密码安全输入、输入法自己的设置和登录窗口始终排除。

采集与增强相互独立。关闭增强时可以记录原生候选和用户选择；采集不会为获得标签而加载模型或新增云端请求。已有云端增强仍按原设置运行。目录变更只影响后续记录，不自动迁移旧数据。停止采集会丢弃尚未写入的队列；“停止中”表示一个已开始的操作正在结束，“已关闭”后不再写入。原有数据保留到用户主动管理。

原始 `.rjcapture` 文件使用 AES-GCM 加密，密钥保存在独立的本机钥匙串条目中，不使用 Jev API 密钥。文件按日期/大小滚动，大小上限、目录不可用、钥匙串不可用或写入失败会暂停采集，不阻塞正常选词。没有明文回退或自动上传。

“预览”在本机解密最多 20 条。预览、导出和删除操作会先关闭采集；完成后保持关闭，需要用户再次启用。删除仅允许选择当前保存目录的采集文件，并移入废纸篓。

## Offline export

The UI streams decrypted records into the local exporter without a plaintext temporary input file. Exports are plaintext and must be reviewed before sharing. Their location is chosen independently of the encrypted capture directory.

- Without a tokenizer directory: exports `records/`, `sft/`, conflicts summary and a quality manifest.
- With a compatible **local** Hugging Face tokenizer directory: also exports `instruction/` with the tokenizer's non-thinking chat template, answer letter and EOS. Tokenizers are never automatically downloaded and remote tokenizer code is disabled.
- A matching local tokenizer is required before claiming that instruction files are ready for a particular model. No paid training or uploads are started.

For advanced filtering of an explicitly decrypted JSONL stream, use `scripts/export_training.py --input - --output NEW_DIRECTORY`, optionally with `--app`, `--from-date`, `--to-date`, `--exclude-text`, `--include-corrected` and `--tokenizer LOCAL_DIRECTORY`. The native UI is the normal decryption entry point; do not extract Keychain keys into command arguments or files. Date-only CLI filters use UTC; explicit timezone offsets are accepted.

The exporter selects committed, covered, uniquely matched human choices with available context; empty context is valid, omitted/unavailable context is separate. Cancelled/raw/ambiguous/absent-target cases are reported rather than relabeled `none`. Corrections conservatively exclude the referenced examples by default. Model choices/probabilities are diagnostic observations, never training targets or input features. Position effects remain observational bias.

Related composition records and normalized matching contexts are grouped into the same split. Exact semantic duplicates are removed and conflicting labels are set aside. Option order is deterministically shuffled with answers remapped. The exporter retains at most 23 real options plus `none`; targets outside that cap are counted and excluded, never silently inserted into the original candidate list. Small/grouped datasets can have empty validation or test splits and are reported accordingly.

## Record schema v1

Each authenticated payload is a JSON object. Candidate IDs are local to its snapshot, while `id` and `composition_id` are UUIDs.

| Field | Meaning |
| --- | --- |
| `schema_version`, `event_type`, `id` | Format and event identity |
| `session_id`, `composition_id`, `segment_index` | Group related partial selections; not independent examples |
| `created_at`, `app_id`, `environment` | UTC time, app bundle identity, known policy/app/schema versions; unavailable dictionary revision explicitly marked |
| `input` | Actual raw/segmented pinyin, display code, abbreviation flag and confirmed prefix |
| `context` | Up to 80 characters, source and availability; truncation is unknown when the host does not expose it, with `limit_reached` reported separately; `text=null` if not captured or excluded by user |
| `baseline` | Bounded native candidates actually observed, with IDs, engine keys, text and original rank |
| `display` | Current displayed page/order and applied source markers |
| `model_windows`, `models` | Actual model options and available responses, separately from the human label |
| `selection` | Matching candidate ID, committed fragment, input method, coverage, observed commit status and host acknowledgement availability |
| `correction` | Initially unknown; separate linked correction events mark observed edits |

Capture freezes the pre-selection snapshot. Partial choices remain grouped and are saved only with the subsequent final commit relationship; ambiguous/unmatched content remains non-training evidence. The host insertion API does not provide a synchronous receipt: records report `host_ack=unknown`, not verified delivery. Nearby edits are observed only when the same client/caret and a bounded read establish a change. No inference is made that an unobserved correction means satisfaction.

No global keyboard log, window titles, document paths, screenshots, clipboard history, HTTP authorization headers or API keys are collected. A pattern filter drops recognized secret-like records; it cannot identify every sensitive phrase in normal text. Application selection and local review remain necessary. Encrypted files copied elsewhere require the same Keychain key to decrypt; selecting a synchronized folder can cause that software to copy the encrypted files, while plaintext exports are readable.

## Validation boundary

Use synthetic inputs and injected test keys/transports for automated tests. Real local acceptance may enable collection only for the dedicated validation app and a disposable directory, then restore collection to off and restore its initial empty app scope. Do not collect normal user apps to make the test pass. Diagnostics expose only counts/state, never captured text.
