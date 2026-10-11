#!/usr/bin/env bash
set -euo pipefail

# Run from a source checkout: bash scripts/bootstrap_dev.sh
# Environment setup is a separate, explicit user command: uv sync --frozen
# That command downloads locked Python dependencies, not model weights.

usage() {
  cat <<'HELP'
Usage: bash scripts/bootstrap_dev.sh [--check-only]

Check macOS arm64, Command Line Tools, uv, original Squirrel, and Wanxiang.
By default, also create local work directories and fetch official rime/squirrel
at commit 876adebaf2f612951dcdca8a591de65401222b9a. An existing checkout must
already have that HEAD and be clean; it is never reset or overwritten.
--check-only performs prerequisite checks without creating files or fetching.

Run these commands explicitly from the repository root to prepare Python:
  uv sync --frozen
  .venv/bin/python scripts/quality_gate.py --help

No Python environment, model, app, or input source is installed by this script.
Your existing ~/Library/Rime remains read-only. Integration fixtures are prepared
by scripts/test_rime_bridge.py; this script does not copy your personal Rime data.
HELP
}

die() { printf 'bootstrap_dev.sh: %s\n' "$*" >&2; exit 1; }
check_only=0
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --check-only) check_only=1 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
UPSTREAM_DIR="$REPO_ROOT/work/upstream/squirrel"
UPSTREAM_URL=https://github.com/rime/squirrel.git
UPSTREAM_COMMIT=876adebaf2f612951dcdca8a591de65401222b9a
ORIGINAL_APP='/Library/Input Methods/Squirrel.app'
RIME_DIR="$HOME/Library/Rime"

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die 'macOS on Apple silicon is required (run outside Rosetta).'
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ $macos_major -ge 14 ]] || die 'macOS 14 or newer is required by the pinned local runtime.'
for tool in git xcode-select xcrun plutil lipo uv; do
  command -v "$tool" >/dev/null 2>&1 || die "missing prerequisite: $tool"
done
developer_dir=$(xcode-select -p) || die 'Select installed Apple Command Line Tools or Xcode first.'
[[ -d "$developer_dir" ]] || die 'The selected developer tools directory does not exist.'
for compiler in clang swiftc; do
  xcrun --find "$compiler" >/dev/null || die "Apple developer tools cannot locate $compiler."
done
sdk_dir=$(xcrun --sdk macosx --show-sdk-path) || die 'The macOS SDK is unavailable.'
[[ -d "$sdk_dir" ]] || die 'The macOS SDK directory does not exist.'

[[ -x "$ORIGINAL_APP/Contents/MacOS/Squirrel" ]] || die "Original Squirrel is required at $ORIGINAL_APP."
bundle_id=$(plutil -extract CFBundleIdentifier raw "$ORIGINAL_APP/Contents/Info.plist")
[[ "$bundle_id" == im.rime.inputmethod.Squirrel ]] || die 'The installed Squirrel bundle is not the original input method.'
for resource in Contents/Frameworks/librime.1.dylib Contents/Resources/Assets.car; do
  [[ -f "$ORIGINAL_APP/$resource" ]] || die "Squirrel prerequisite missing: $resource"
done
for resource in Contents/Frameworks/Sparkle.framework Contents/SharedSupport; do
  [[ -d "$ORIGINAL_APP/$resource" ]] || die "Squirrel prerequisite missing: $resource"
done
lipo -verify_arch arm64 "$ORIGINAL_APP/Contents/MacOS/Squirrel" >/dev/null || die 'Squirrel does not support arm64.'
lipo -verify_arch arm64 "$ORIGINAL_APP/Contents/Frameworks/librime.1.dylib" >/dev/null || die 'Installed librime does not support arm64.'
[[ -f "$RIME_DIR/wanxiang.schema.yaml" ]] || die 'Install Wanxiang in ~/Library/Rime first (wanxiang.schema.yaml is missing).'
[[ -f "$RIME_DIR/build/wanxiang.schema.yaml" ]] || die 'Deploy Wanxiang with original Squirrel first (build/wanxiang.schema.yaml is missing).'

verify_upstream() {
  [[ ! -L "$UPSTREAM_DIR" && -d "$UPSTREAM_DIR/.git" ]] || die "Existing upstream path is not a standalone checkout: $UPSTREAM_DIR"
  [[ $(git -C "$UPSTREAM_DIR" remote get-url origin) == "$UPSTREAM_URL" ]] || die 'Existing upstream origin is not the official HTTPS rime/squirrel repository.'
  [[ $(git -C "$UPSTREAM_DIR" rev-parse --verify HEAD) == "$UPSTREAM_COMMIT" ]] || die "Existing upstream HEAD differs from $UPSTREAM_COMMIT; move it aside explicitly before retrying."
  [[ -z $(git -C "$UPSTREAM_DIR" status --porcelain --untracked-files=all) ]] || die 'Existing upstream has local changes; preserve them before retrying.'
}

if [[ -e "$UPSTREAM_DIR" || -L "$UPSTREAM_DIR" ]]; then
  verify_upstream
fi
if [[ "$check_only" -eq 1 ]]; then
  printf 'Prerequisites passed. Upstream fetching and work-directory creation were not requested.\n'
  exit 0
fi

mkdir -p "$REPO_ROOT/work/upstream" "$REPO_ROOT/work/evidence" \
  "$REPO_ROOT/work/build-probe" "$REPO_ROOT/work/integration" \
  "$REPO_ROOT/artifacts/coverage" "$REPO_ROOT/artifacts/quality-gate"

if [[ ! -e "$UPSTREAM_DIR" ]]; then
  # Fetch into a new directory, leaving any existing checkout untouched on failure.
  stage_dir=$(mktemp -d "$REPO_ROOT/work/upstream/.squirrel.XXXXXX")
  trap 'rm -rf -- "$stage_dir"' EXIT
  git init -q "$stage_dir"
  git -C "$stage_dir" remote add origin "$UPSTREAM_URL"
  GIT_TERMINAL_PROMPT=0 git -C "$stage_dir" -c http.connectTimeout=30 \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    fetch --depth=1 origin "$UPSTREAM_COMMIT"
  git -C "$stage_dir" checkout --detach "$UPSTREAM_COMMIT"
  [[ $(git -C "$stage_dir" rev-parse --verify HEAD) == "$UPSTREAM_COMMIT" ]] || die 'Fetched upstream HEAD did not match the locked commit.'
  [[ ! -e "$UPSTREAM_DIR" && ! -L "$UPSTREAM_DIR" ]] || die 'Upstream path appeared during fetching; leaving it untouched.'
  mv "$stage_dir" "$UPSTREAM_DIR"
  trap - EXIT
fi
verify_upstream
printf 'Prerequisites passed. Official Squirrel source verified at %s.\n' "$UPSTREAM_COMMIT"
printf 'Next, explicitly run from the repository root: uv sync --frozen\n'
