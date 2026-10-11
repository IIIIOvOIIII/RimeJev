#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rime-jev-swift-core.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

swiftc \
  -parse-as-library \
  "$project_dir/native/JevCore.swift" \
  "$project_dir/native/tests/JevCoreTests.swift" \
  -o "$temporary_dir/JevCoreTests"

"$temporary_dir/JevCoreTests"
