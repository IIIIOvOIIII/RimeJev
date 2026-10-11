# Synthetic real-Rime bridge fixture

This fixture was authored for the public Rime-Jev regression suite. It contains
hand-written common words and deliberately artificial numbered entries. The
codes and descending integer weights are test data, not a language corpus or a
copy of anyone's dictionary, usage history, backups, or installed Rime data.

`wanxiang` is only the schema ID required by `native/rime_probe.mm`. This fixture
is not the Wanxiang distribution and does not measure Wanxiang's dictionary or
ranking quality.

## Inputs and isolation

Run `.venv/bin/python scripts/test_rime_bridge.py` from the project root on macOS
with Squirrel installed at `/Library/Input Methods/Squirrel.app` and the Xcode
command line tools available. The Python runner uses only the standard library.

`scripts/prepare_bridge_fixture.py` copies these YAML files and the current
public `rime/lua/jev` source into a new temporary directory under ignored
`work/`. Squirrel's real `rime_deployer` compiles the dictionary and schema there.
The compiler and probe both receive an empty shared-data directory, so no
installed dictionaries, essay model, personal configuration, or backups supply
missing data. Each probe receives its own disposable copy of the compiled
fixture. User dictionary learning is disabled. Temporary fixture directories
are removed at the end of the run.

The installed Squirrel app supplies only the executable and native libraries;
the test does not install or configure an input method, call a model, read
credentials, or send operating-system keyboard events. `local` and `jev` name
controlled recommendation properties injected into the real Lua bridge.

## Candidate construction and coverage

- `sj`: 128 unique candidates with strictly descending weights. `睡觉` is
  deliberately rank 12, beyond the initial eight-candidate scoring window.
- `youxiang`: 128 unique candidates beginning `邮箱`, `油香`, `油箱`; all later
  entries are explicitly numbered synthetic strings. Both this list and `sj`
  use Chinese digits for their artificial labels, because the public bridge
  accepts only all-Chinese candidate text.
- `qiche`: one candidate, `汽车`, used for a confirmed prefix in
  `qicheyouxiang` and for sampling an exhausted short list.
- `cap`: one Chinese candidate, `边界`, followed by 127 artificial ASCII strings.
  This keeps the snapshot below 24 Chinese entries while providing enough raw
  candidates to exercise all eight sampling batches. The dictionary has 385
  entries in total.
- `script_translator` produces native phrase candidates eligible for the public
  bridge. A second, independently compiled variant changes only the translator
  to `table_translator`. The `cap` input then produces a genuinely protected
  table candidate: an injected recommendation must preserve the full original
  order and leave the applied property empty. The suite verifies the native
  `phrase` and `table` types encoded by the public bridge's identity keys.

The original 84-probe matrix covers target ranks 1, 2, 3 and 12 for both
recommendation sources; direct selections 0/1/2 and real Rime Space/2/3 key
handling; all 128 candidates including their tail order and multiplicity;
missing, stale and invalid results; restore, repeated results and reapply;
confirmed-prefix composition; and sampling without moving the page, highlight,
caret or input. Two additional probes cover short-list exhaustion and the
protected table translator, for 86 probes in total.

The rank-12 assertion is preserved. The former private fixture's partial-input
assertion (`64` raw candidates and fewer than `24` eligible candidates) does not
describe this fixture: its suffix has 128 full-span candidates, so partial-input
sampling reaches the 24-eligible-candidate limit. The table-translator probe
separately reaches the 64-raw-candidate limit in eight batches of eight, with one
Chinese candidate that is protected from promotion. The runner continues to check the default score limit
of 8, maximum score limit of 24, and scan cap of 64.

Generated results, source SHA-256 hashes and elapsed time are written to
`work/evidence/bridge-tests.json`; individual probe rows and compiler/runtime
logs are alongside it. These results demonstrate the bridge against synthetic
real-Rime candidates, not model quality, the full Wanxiang distribution, or
installed-input-method/UI acceptance.
