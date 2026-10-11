# Architecture and candidate contract

The native Squirrel input method owns keyboard events, composition, candidate display, and submission. Rime/Wanxiang creates the candidates. `rime/lua/jev/bridge.lua` exposes stable keys for comparable genuine candidates and applies a validated selection to the same candidate objects.

`native/JevCore.swift` coordinates asynchronous decisions and rejects stale versions. `native/JevCommittedContext.swift` maintains a bounded, verified recent input context. `native/JevIntegration.swift` connects those pieces to the native IME and per-application settings. Python's Unix-socket runtime supplies the Jev and local this-that-model providers.

From 0.2.4 onward, an accepted choice equal to the original first candidate only adds its source badge. Another choice moves to position two while the original first remains selected by default. The chosen candidate is removed from its old position; all others preserve their relative order. Display and selection use the same rebuilt engine menu. Badges are decoration and are never committed as text.

Candidates are immediately usable. Requests are debounced by 260ms. The current model’s configured timeout bounds placement and final expiry, including debounce and sampling; the runtime receives only the remaining time. Defaults are 600ms for Jev/TT/Tev0.8B and 2000ms for Tev4B, with per-model 300–10000ms settings. The compact UI does not add a late badge after the deadline. Sorting and commit interactions lock the version. No match, low confidence, failures, invalid/stale callbacks, or loading leave the native path available.

Full pinyin considers eight candidates. Abbreviated or mixed pinyin can asynchronously materialize up to 24 comparable candidates, scanning no more than 64 raw candidates in small main-loop batches. Sampling time counts toward the original deadlines. Explicitly protected/custom candidates cause conservative abstention.

Local failure never changes the provider to cloud. Enhancement is off by default; users explicitly choose either an all-app default or individual application profiles. Credentials, model weights, user dictionaries, runtime logs, and settings are not versioned.


0.3.0 adds `tev-0.8b` and `tev-4b` as distinct local provider identities. Both display `✦ Tev`; the existing `local` provider remains the compatible identifier for TT and displays `✦ TT`. Source labels no longer depend on whether a recommendation matched the first word. The first-preserved/second-slot placement contract is unchanged.

Tev's managed local service is isolated from an existing system Ollama service. Its downloads are explicit, runtime/model identities pinned, endpoint loopback-only, proxy/redirect forwarding disabled, and cloud features off. Model switches invalidate old decisions; missing resources, loading, and timeouts retain native candidates. Tev reserves one of its 24 trained options for `none`.

## 0.4.0 dual-mode contract

Each app now selects off/cloud/local/dual separately from its local backend and two-row provider priority. Legacy provider IDs resolve to local-only profiles. The runtime manager keeps a dictionary of selected processes, permits Jev plus exactly one local model, invalidates callbacks on profile changes, and releases old local resources before loading a replacement. Changing a local model can retain the cloud process.

Each provider has its own coordinator/deadline and validates against the same original candidate snapshot. Valid responses are merged incrementally with JevCandidatePlan; source priority is independent of arrival time. All coordinators are invalidated on input/context changes and frozen on selection. Dual-mode partial results are not reused from the single-model cache.

The v2 Lua payload binds epoch, raw input, complete candidate-window signature, at most two distinct keys, and at most one cloud/local source each. Native first is always emitted first, requested distinct words follow, then remaining original objects in relative order. A first-word match gets its source badge; duplicate recommendations merge sources. The applied marker is the whole v2 payload. No generated word or placeholder is inserted.

Keychain direct keys are user-entered and masked, not settings fields. The Jev-only runtime credential flag reads a bounded private pipe; legacy Vault mode stays separate. Shift feedback compares actual Rime ascii_mode before/after modifier processing and uses its own nonactivating panel, leaving candidate selection untouched.

## 0.4.1 default profile and app overrides

Optional `defaultMode`, `defaultLocalModel`, and `defaultModelOrder` resolve to off/TT/Jev-first when absent. The old `mode` field is a last-selection value and is never a global default. An `appModes` key creates a complete override, preserving legacy local IDs and former fallback choices. First per-app edits snapshot the effective inherited profile before changing one field. Removing an override removes its mode/local/order and legacy enrollment record; it then inherits again.

`allowedApps` remains encoded for compatibility but no longer gates enhancement. Eligibility uses the resolved mode plus secure-input and known-app checks; the IME's own settings are excluded. Global edits invalidate cached decisions and rebuild all adapters, while runtime selection follows the current app's effective profile. A reused input controller refreshes its coordinator when its application identity changes.

Settings open in the all-app default scope, with a separate current-app scope and follow-default button. Editing the default does not force-load a model for an app that retains a different override. Download selection follows the edited scope; credential and timeout controls remain global. The user requested the live default to stay off during this upgrade and UI verification.

## 0.4.2 same-line context

JevLineContext resolves a position-bound snapshot independently of the IME's recent commit cache. The adapter reads a bounded 512-UTF16-unit host slice ending at the marked-text start (or selected-range start), validates the returned actual range, excludes text after that boundary, clips at the last logical newline and retains at most 80 complete characters. Confirmed Rime prefixes are appended once. A successful empty read is authoritative; unavailable text can use only verified commits, otherwise an empty-context request. No screen/OCR/clipboard/Accessibility fallback is used.

Initial context reads are coalesced behind the existing debounce, after native rendering; superseded work is discarded before reading. A usable caret/composition anchor is required even for empty-context requests. Dispatch and application revalidate client, selection, marked range and exact UTF16 context. Provider deadlines include reading and sampling; dispatch uses the remaining budget and application checks it again. A host read exceeding 50ms suppresses subsequent text fetches for that client for five seconds; this is backoff, not a hard timeout for the first synchronous IMK call. Cached single-provider choices are bound to the host snapshot and original candidate signature, and are never shared with dual mode. Diagnostics expose source/reason/length/timing only.

The selected mode authorizes the same bounded context for all selected providers. Off, secure input and the IME itself do not read it. Existing/pasted same-line text may therefore reach Jev when the user selected cloud or dual mode. No text is persisted in diagnostics.

## 0.5.0 opt-in training capture

Training settings have an independent disabled-by-default master switch, selected/all-except-excluded app scope, local directory, context/model switches and quota. Missing settings never inherit enhancement consent. JevTrainingCapture associates native snapshots, displayed order and input intent with actual Rime commits; partial candidates share a composition group. Model outputs are observations, never gold labels. Unavailable context, unsupported coverage and unconfirmed host acknowledgement are explicit rather than fabricated.

JevTrainingStore owns bounded asynchronous AES-GCM writes, a separate Keychain key, generation invalidation, private file permissions, rotation and quota. Disabled configuration never creates a key or directory. A stopped generation cannot accept new submissions; off status acknowledges quiescence. Custom missing directories pause instead of being recreated. The UI manages scope/path, preview, local plaintext export and recoverable deletion. These operations disable capture and use background workers. The offline exporter filters real covered choices, deduplicates/conflict-checks, groups related examples before splitting and renders optional model-specific prompt/completion using a local tokenizer only.
