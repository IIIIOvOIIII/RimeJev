#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rime-jev-training-store.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

swiftc -parse-as-library \
  -target "$(uname -m)-apple-macosx13.0" \
  -framework Foundation -framework CryptoKit -framework Security \
  "$project_dir/native/JevTrainingSettings.swift" \
  "$project_dir/native/JevTrainingStore.swift" \
  "$project_dir/native/tests/JevTrainingStoreTests.swift" \
  -o "$temporary_dir/JevTrainingStoreTests"

"$temporary_dir/JevTrainingStoreTests"
