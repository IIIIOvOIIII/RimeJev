#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
task_temp=$(mktemp -d "${TMPDIR:-/tmp}/rime-jev-capture.XXXXXX")
trap 'rm -rf "$task_temp"' EXIT
swiftc -parse-as-library native/JevCore.swift native/JevCandidatePlan.swift native/JevLineContext.swift native/JevTrainingSettings.swift native/JevTrainingCapture.swift native/tests/JevTrainingCaptureTests.swift -o "$task_temp/test"
"$task_temp/test"
