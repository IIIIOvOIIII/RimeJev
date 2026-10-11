# Third-party notices

## Squirrel

`native/squirrel/sources` is derived from [rime/squirrel](https://github.com/rime/squirrel) commit `876adebaf2f612951dcdca8a591de65401222b9a` (Squirrel 1.1.2). Upstream copyright headers and `native/squirrel/LICENSE.txt` are retained. Squirrel is GPL v3; the root `LICENSE` contains that license for this derivative project.

## librime

`native/include/rime_api.h` retains its upstream RIME Developers copyright and BSD notice. Native builds obtain headers pinned to commit `a251145d3aafa33871824a40bbec04c966bd8b56` and reuse the user's installed librime binary. See [librime](https://github.com/rime/librime).

## External dependencies and data

- [this-that-model SDK](https://github.com/FLock-io/this-that-model): commit `6af11c63c8bb260aa4bed2b7717f33f25decd16e`, fetched separately through `uv.lock`.
- [this-that-model-1.2 weights](https://huggingface.co/flock-io/this-that-model-1.2): revision `c4d1c30b8d512d278726de439b8cc81fccc70c8f`, downloaded separately and hash-verified. Weights are not in this repository.
- [Sparkle](https://github.com/sparkle-project/Sparkle): build metadata pinned to `41847a58cdef7506b257591fcca6f9495df591d4`; the app build reuses the user's installed framework. No prebuilt framework is distributed here.
- [Wanxiang](https://github.com/amzxyz/rime_wanxiang): installed separately by the user. No personal dictionary, learned frequency database, or private input history is redistributed.

Each external project retains its own copyright and licensing terms. Synthetic regression fixtures and evaluation sentences in this repository are test data, not real user input or evidence of model accuracy.
