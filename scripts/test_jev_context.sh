#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd "$script_dir/.." && pwd)
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/rime-jev-context.XXXXXX")
trap 'rm -rf "$temporary_dir"' EXIT

swiftc \
  -parse-as-library \
  "$project_dir/native/JevCommittedContext.swift" \
  "$project_dir/native/tests/JevCommittedContextTests.swift" \
  -o "$temporary_dir/JevCommittedContextTests"

"$temporary_dir/JevCommittedContextTests"

swiftc -parse-as-library \
  "$project_dir/native/JevLineContext.swift" \
  "$project_dir/native/tests/JevLineContextTests.swift" \
  -o "$temporary_dir/JevLineContextTests"
"$temporary_dir/JevLineContextTests"
