# Architecture and candidate contract

The native Squirrel input method owns keyboard events, composition, candidate display, and submission. Rime/Wanxiang creates the candidates. `rime/lua/jev/bridge.lua` exposes stable keys for comparable genuine candidates and applies a validated selection to the same candidate objects.

`native/JevCore.swift` coordinates asynchronous decisions and rejects stale versions. `native/JevCommittedContext.swift` maintains a bounded, verified recent input context. `native/JevIntegration.swift` connects those pieces to the native IME and per-application settings. Python's Unix-socket runtime supplies the Jev and local this-that-model providers.

In 0.2.4, an accepted choice equal to the original first candidate only adds its source badge. Another choice moves to position two while the original first remains selected by default. The chosen candidate is removed from its old position; all others preserve their relative order. Display and selection use the same rebuilt engine menu. Badges are decoration and are never committed as text.

Candidates are immediately usable. Requests are debounced by 260ms; automatic placement must arrive within 600ms. The coordinator's final cutoff is 1500ms; the compact UI drops late annotation when there is no stable badge space. Sorting and commit interactions lock the version. No match, low confidence, failures, invalid/stale callbacks, or loading leave the native path available.

Full pinyin considers eight candidates. Abbreviated or mixed pinyin can asynchronously materialize up to 24 comparable candidates, scanning no more than 64 raw candidates in small main-loop batches. Sampling time counts toward the original deadlines. Explicitly protected/custom candidates cause conservative abstention.

Local failure never changes the provider to cloud. All modes are off by default; users explicitly enable a provider per application. Credentials, model weights, user dictionaries, runtime logs, and settings are not versioned.
