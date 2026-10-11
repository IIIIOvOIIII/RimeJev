# Validation — 0.2.4 public source

The original development version passed 96 backend tests and 84 real-Rime regression probes. It was installed on an Apple Silicon Mac, and the user confirmed that a recommendation appeared in the second slot and digit 2 committed it correctly. These observations belong to that development installation, not every macOS host.

The public package preserves the ranking/placement, context, and timing logic. Publication changes remove machine-specific paths and credential-service defaults, make the quality gate self-contained, and replace private dictionary snapshots with deterministic synthetic Rime fixtures. No credential, learned user dictionary, screenshot of a user's applications, runtime log, or model weight is published.

The engine probes use controlled recommendation responses, not real model calls. They verify candidate identity, unchanged first choice, second-slot placement, relative order/count, submission, stale handling, restoration, and repeated application. Model accuracy and visual acceptance must be reported separately.

The local model and Jev can make an incorrect or low-confidence choice. Cold loading/network setup may exceed the display deadline, in which case native ordering remains. No bulk model evaluation is part of installation.

Public package verification results will be recorded here before publication.
