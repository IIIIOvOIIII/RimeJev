# Training capture / 训练数据采集

0.5.0 introduces optional, local encrypted collection. Collection starts **off**, independently of cloud/local enhancement. Upgrades never infer consent from an enhancement profile. The initial selected-app list is empty.

## 使用

打开输入法菜单“训练数据采集与管理…”或设置中的“训练数据…”。选择保存文件夹及采集应用，按需选择上下文、模型结果和保存上限，最后明确启用并保存。默认路径为 `~/Library/Application Support/Rime-Jev/TrainingData`，默认上限 1 GiB。范围可以是仅选中应用，或所有应用减去排除列表。密码安全输入、输入法自己的设置和登录窗口始终排除。

采集与增强相互独立。关闭增强时可以记录原生候选和用户选择；采集不会为获得标签而加载模型或新增云端请求。已有云端增强仍按原设置运行。目录变更只影响后续记录，不自动迁移旧数据。停止采集会丢弃尚未写入的队列；“停止中”表示一个已开始的操作正在结束，“已关闭”后不再写入。已有数据受下述容量保留策略管理；关闭采集时不会自动清理。

0.5.1 起，原始记录先使用本机 LZFSE 压缩，再用 AES-GCM 加密，按本机日历日期保存到 `.rjcapture` 文件。当天记录即时压缩，不必等到午夜；文件还会按较小分段滚动，便于保留当天较新的记录。不可压缩的单条记录保持原始负载后加密，避免体积反增。密钥保存在独立的本机钥匙串条目中，不使用 Jev API 密钥。没有明文临时采集文件、明文回退或自动上传。

预计新记录写入后达到容量上限的 **90%** 时，按文件日期从旧到新清理；同一天按最后写入时间排序，直到预计占用降至约 **80%**。清理以完整文件为单位，实际剩余空间会有差异。自动清理为永久删除，**不会移到废纸篓**，以真正释放空间；仅清理当前采集目录内符合本项目命名和文件校验的采集文件，其他文件保持不变。上限按采集文件实际大小计算，不包含用户另选目录导出的明文训练集。当前文件也可在必要时滚动清理，新记录优先保留。

0.5.0 文件仍可直接预览、导出。下一次启用采集并写入时，会在后台尝试压缩尚未处理的旧格式文件：逐条解密、压缩、重新加密到临时文件，完整写入成功且体积变小后才原子替换；原日期和最后写入时间保持不变。压缩前后训练记录内容不变，旧格式中不可缩小的文件原样保留。关闭采集、预览和导出不触发这类迁移或自动清理。

正常容量压力通过清理旧记录继续采集。目录、钥匙串、加密或写入异常仍会暂停采集；单条记录超过容量上限或没有可安全清理的旧文件时也会暂停，不阻塞正常选词。设置窗口显示本次启动自动清理的文件数和释放空间。

“预览”在本机解密最多 20 条。预览、导出和删除操作会先关闭采集；完成后保持关闭，需要用户再次启用。手动删除仅允许选择当前保存目录的采集文件，并移入废纸篓；这与上述自动容量清理不同。

## Daily compression and retention (0.5.1)

New records are LZFSE-compressed before AES-GCM encryption and grouped by the Mac's local calendar day, including immediate compression of today's writes. Incompressible records use an encrypted raw payload instead. Segments rotate at the smaller of 8 MiB or 10% of the configured quota; an individual record may exceed that segment target if it still fits the quota.

A projected usage of 90% triggers oldest-file deletion toward 80%, using filename day and then last-write time. Cleanup permanently unlinks only validated, project-named captures in the selected directory; it does not move them to Trash or remove unrelated files. The newest incoming record is retained. Usage counts actual capture file bytes, excluding separately exported datasets. Off/read-only operations do not compact or prune. Normal quota pressure no longer pauses collection; impossible record sizes and genuine storage/key errors can still pause it.

Legacy files remain readable. On the next enabled write, closed legacy files are compacted record-by-record using an encrypted temporary file and atomic replacement, only if the complete replacement is smaller. Original day/last-write time are retained for eviction order. The previous file survives interrupted or unsuccessful compaction. No plaintext temporary capture is created. Manual deletion remains recoverable through Trash. Back up any records you want to retain before they age out of the selected capacity.

### Storage compatibility

The record schema below stays at version 1. The encrypted **envelope** is version 2 for new writes: `{schema_version: 2, sealed: ...}`. AES-GCM authenticates `RimeJev.capture.v2` as additional data; authenticated plaintext starts with one codec byte (`0` = raw, `1` = LZFSE), followed by the record bytes or compressed stream. Decompression is bounded to 128 KiB per record. Legacy envelope version 1 has no codec byte or additional authenticated data and remains supported for reads.

Older 0.5.0 binaries cannot read the new envelope. If rolling back the app, retain captures for a 0.5.1-or-newer reader, or explicitly export the required records beforehand. The existing Keychain key remains unchanged.

LZFSE uses Apple's [Compression framework](https://developer.apple.com/documentation/compression/compression_lzfse); ciphertext itself is never used as the compression input.

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

Use synthetic inputs and injected test keys/transports for automated tests. Real local acceptance may enable collection only for the dedicated validation app and a disposable directory, then restore collection to off and restore the user’s prior path and app scope. Do not collect normal user apps to make the test pass. Diagnostics expose only counts/state, never captured text.
