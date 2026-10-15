#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Build the upstream Squirrel target without xcodebuild. The output is a
# disposable local probe and is intentionally never installed as an input
# source.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
UPSTREAM_DIR=${SQUIRREL_UPSTREAM_DIR:-"$REPO_ROOT/work/upstream/squirrel"}
BUILD_ROOT=${SQUIRREL_BUILD_ROOT:-"$REPO_ROOT/work/build-probe"}
APP_PATH=${SQUIRREL_APP_PATH:-"$BUILD_ROOT/Squirrel.app"}
INSTALLED_APP=${SQUIRREL_INSTALLED_APP:-"/Library/Input Methods/Squirrel.app"}
MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-13.0}
PRODUCT_VERSION=${SQUIRREL_VERSION:-0.5.2}
PRODUCT_BUNDLE_IDENTIFIER=${SQUIRREL_BUNDLE_IDENTIFIER:-im.lynx.inputmethod.RimeJev}

resolve_repo_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/$1" ;;
  esac
}

if [[ -n ${SOURCE_DIR:-} ]]; then
  SOURCE_DIR=$(resolve_repo_path "$SOURCE_DIR")
elif [[ -f "$REPO_ROOT/native/squirrel/sources/Main.swift" ]]; then
  SOURCE_DIR="$REPO_ROOT/native/squirrel/sources"
else
  SOURCE_DIR="$UPSTREAM_DIR/sources"
fi
if [[ -f "$SOURCE_DIR/sources/Main.swift" && ! -f "$SOURCE_DIR/Main.swift" ]]; then
  SOURCE_DIR="$SOURCE_DIR/sources"
fi

BRIDGING_HEADER=${BRIDGING_HEADER:-}
if [[ -z "$BRIDGING_HEADER" ]]; then
  if [[ -f "$SOURCE_DIR/Squirrel-Bridging-Header.h" ]]; then
    BRIDGING_HEADER="$SOURCE_DIR/Squirrel-Bridging-Header.h"
  else
    BRIDGING_HEADER="$UPSTREAM_DIR/sources/Squirrel-Bridging-Header.h"
  fi
else
  BRIDGING_HEADER=$(resolve_repo_path "$BRIDGING_HEADER")
fi

# These commits are the submodule revisions pinned by the upstream 1.1.2
# source tree and match the installed Squirrel dependencies.
RIME_COMMIT=a251145d3aafa33871824a40bbec04c966bd8b56
SPARKLE_COMMIT=41847a58cdef7506b257591fcca6f9495df591d4

die() {
  printf 'build_squirrel.sh: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

for command_name in xcrun swiftc clang codesign lipo otool plutil ditto curl tar file; do
  require_command "$command_name"
done

[[ -d "$UPSTREAM_DIR" ]] || die "upstream source directory not found: $UPSTREAM_DIR"
[[ -d "$SOURCE_DIR" ]] || die "source directory not found: $SOURCE_DIR"
[[ -f "$BRIDGING_HEADER" ]] || die "bridging header not found: $BRIDGING_HEADER"
[[ -f "$UPSTREAM_DIR/resources/Info.plist" ]] || die "upstream Info.plist is missing"

[[ -d "$INSTALLED_APP/Contents/Frameworks" ]] || die "installed Squirrel framework directory not found: $INSTALLED_APP"
[[ -f "$INSTALLED_APP/Contents/Frameworks/librime.1.dylib" ]] || die "installed librime.1.dylib not found"
[[ -d "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework" ]] || die "installed Sparkle.framework not found"
[[ -f "$INSTALLED_APP/Contents/Resources/Assets.car" ]] || die "installed Assets.car not found"

SDKROOT=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
[[ -d "$SDKROOT" ]] || die "macOS SDK not found: $SDKROOT"

if [[ -n ${SQUIRREL_ARCHS:-} ]]; then
  ARCHS=()
  IFS=' ,' read -r -a ARCHS <<< "$SQUIRREL_ARCHS"
else
  ARCHS=(arm64 x86_64)
fi

HAS_SUPPORTED_ARCH=0
for arch in "${ARCHS[@]}"; do
  if [[ "$arch" == arm64 || "$arch" == x86_64 ]]; then
    HAS_SUPPORTED_ARCH=1
    break
  fi
done
[[ "$HAS_SUPPORTED_ARCH" -eq 1 ]] || die "SQUIRREL_ARCHS must include arm64 or x86_64 (got: ${ARCHS[*]})"

for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *) die "unsupported architecture: $arch" ;;
  esac
done

CACHE_ROOT="$BUILD_ROOT/.cache"
FRAMEWORK_BUILD_ROOT="$CACHE_ROOT/frameworks"
RIME_CACHE_ROOT="$CACHE_ROOT/librime-$RIME_COMMIT"
SPARKLE_CACHE_ROOT="$CACHE_ROOT/sparkle-$SPARKLE_COMMIT"
STAGE_ROOT="$BUILD_ROOT/.stage"

mkdir -p "$CACHE_ROOT" "$FRAMEWORK_BUILD_ROOT"

download_and_extract() {
  local url=$1
  local archive=$2
  local extract_root=$3
  local marker=$4
  local extract_tmp source_root

  if [[ -f "$marker" ]]; then
    return
  fi

  mkdir -p "$(dirname -- "$archive")"
  if [[ ! -f "$archive" ]]; then
    printf 'Downloading pinned dependency source: %s\n' "$url"
    curl --fail --location --retry 2 --silent --show-error "$url" --output "$archive"
  fi

  extract_tmp=$(mktemp -d "$CACHE_ROOT/.extract.XXXXXX")
  tar -xzf "$archive" -C "$extract_tmp"
  source_root=$(find "$extract_tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)
  [[ -n "$source_root" && -d "$source_root" ]] || die "could not locate extracted source from $archive"

  if [[ -e "$extract_root" || -L "$extract_root" ]]; then
    rm -R -- "$extract_root"
  fi
  mkdir -p "$extract_root"
  ditto "$source_root/" "$extract_root/"
  : > "$marker"
  rm -R -- "$extract_tmp"
}

if [[ -f "$UPSTREAM_DIR/librime/src/rime_api.h" && -f "$UPSTREAM_DIR/librime/src/rime/key_table.h" && -f "$UPSTREAM_DIR/librime/src/rime_api_stdbool.h" ]]; then
  RIME_SOURCE_ROOT="$UPSTREAM_DIR/librime"
else
  download_and_extract \
    "https://github.com/rime/librime/archive/$RIME_COMMIT.tar.gz" \
    "$CACHE_ROOT/librime-$RIME_COMMIT.tar.gz" \
    "$RIME_CACHE_ROOT" \
    "$RIME_CACHE_ROOT/.complete"
  RIME_SOURCE_ROOT="$RIME_CACHE_ROOT"
fi

RIME_SRC_DIR="$RIME_SOURCE_ROOT/src"
RIME_INCLUDE_DIR="$RIME_SOURCE_ROOT/include"
[[ -f "$RIME_SRC_DIR/rime_api.h" ]] || die "librime public source headers are missing under $RIME_SRC_DIR"
[[ -f "$RIME_SRC_DIR/rime/key_table.h" ]] || die "librime key_table.h is missing under $RIME_SRC_DIR"
[[ -f "$RIME_SRC_DIR/rime_api_stdbool.h" ]] || die "librime rime_api_stdbool.h is missing under $RIME_SRC_DIR"

RIME_EXTRA_INCLUDE_DIRS=()
if [[ -f "$REPO_ROOT/native/include/rime_api.h" ]]; then
  # Reuse the already downloaded official header when the Jev prototype has
  # one. The build never overwrites it; the pinned cache supplies any sibling
  # public headers that are not present there.
  RIME_EXTRA_INCLUDE_DIRS=(-I "$REPO_ROOT/native/include")
fi

if [[ -f "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework/Headers/Sparkle.h" ]]; then
  SPARKLE_HEADER_ROOT="$INSTALLED_APP/Contents/Frameworks/Sparkle.framework/Headers"
elif [[ -f "$UPSTREAM_DIR/Sparkle/Sparkle/Sparkle.h" ]]; then
  SPARKLE_HEADER_ROOT="$UPSTREAM_DIR/Sparkle/Sparkle"
else
  download_and_extract \
    "https://github.com/sparkle-project/Sparkle/archive/$SPARKLE_COMMIT.tar.gz" \
    "$CACHE_ROOT/sparkle-$SPARKLE_COMMIT.tar.gz" \
    "$SPARKLE_CACHE_ROOT" \
    "$SPARKLE_CACHE_ROOT/.complete"
  SPARKLE_HEADER_ROOT="$SPARKLE_CACHE_ROOT/Sparkle"
fi

[[ -f "$SPARKLE_HEADER_ROOT/Sparkle.h" ]] || die "Sparkle public headers are missing under $SPARKLE_HEADER_ROOT"

# The installed framework was copied with public headers removed. Add the
# pinned public headers and a minimal module map to a build-only framework
# copy; the installed framework itself is read-only input.
SPARKLE_BUILD_FRAMEWORK="$FRAMEWORK_BUILD_ROOT/Sparkle.framework"
if [[ -e "$SPARKLE_BUILD_FRAMEWORK" || -L "$SPARKLE_BUILD_FRAMEWORK" ]]; then
  rm -R -- "$SPARKLE_BUILD_FRAMEWORK"
fi
ditto "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework" "$SPARKLE_BUILD_FRAMEWORK"
mkdir -p "$SPARKLE_BUILD_FRAMEWORK/Headers" "$SPARKLE_BUILD_FRAMEWORK/Modules"
ditto "$SPARKLE_HEADER_ROOT/" "$SPARKLE_BUILD_FRAMEWORK/Headers/"
printf '%s\n' \
  'framework module Sparkle {' \
  '  header "Sparkle.h"' \
  '  export *' \
  '}' > "$SPARKLE_BUILD_FRAMEWORK/Modules/module.modulemap"

if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
  rm -R -- "$APP_PATH"
fi
if [[ -e "$STAGE_ROOT" || -L "$STAGE_ROOT" ]]; then
  rm -R -- "$STAGE_ROOT"
fi
mkdir -p "$STAGE_ROOT" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/SharedSupport"

# Use the source plist and installed, version-matched resources. The latter
# include Assets.car, the icon, localizations, and the prebuilt Rime data that
# the upstream Xcode target normally places in the app bundle.
ditto "$UPSTREAM_DIR/resources/Info.plist" "$APP_PATH/Contents/Info.plist"
ditto "$INSTALLED_APP/Contents/Resources/" "$APP_PATH/Contents/Resources/"
ditto "$INSTALLED_APP/Contents/SharedSupport/" "$APP_PATH/Contents/SharedSupport/"
if [[ -f "$INSTALLED_APP/Contents/PkgInfo" ]]; then
  ditto "$INSTALLED_APP/Contents/PkgInfo" "$APP_PATH/Contents/PkgInfo"
fi

plutil -replace CFBundleIdentifier -string "$PRODUCT_BUNDLE_IDENTIFIER" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$PRODUCT_VERSION" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "Rime" "$APP_PATH/Contents/Info.plist"
if ! plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  plutil -insert CFBundleShortVersionString -string "$PRODUCT_VERSION" "$APP_PATH/Contents/Info.plist"
else
  plutil -replace CFBundleShortVersionString -string "$PRODUCT_VERSION" "$APP_PATH/Contents/Info.plist"
fi
if ! plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
  plutil -insert CFBundleDisplayName -string "Squirrel Input Method" "$APP_PATH/Contents/Info.plist"
fi

python3 - "$APP_PATH" "$PRODUCT_BUNDLE_IDENTIFIER" <<'PY'
import pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]); identifier=sys.argv[2]
if identifier != 'im.rime.inputmethod.Squirrel':
    def rewrite(value):
        if isinstance(value,str): return value.replace('im.rime.inputmethod.Squirrel',identifier)
        if isinstance(value,list): return [rewrite(x) for x in value]
        if isinstance(value,dict): return {rewrite(k):rewrite(v) for k,v in value.items()}
        return value
    path=app/'Contents/Info.plist'
    p=rewrite(plistlib.loads(path.read_bytes()))
    p.update(CFBundleDisplayName='鼠须管 Jev', CFBundleName='鼠须管 Jev', InputMethodConnectionName='RimeJev_Connection', SUEnableAutomaticChecks=False)
    path.write_bytes(plistlib.dumps(p))
    names = {'CFBundleDisplayName': '鼠须管 Jev', 'CFBundleName': '鼠须管 Jev',
             identifier: '鼠须管 Jev', identifier+'.Hans': '鼠须管 Jev',
             identifier+'.Hant': '鼠须管 Jev（繁体）'}
    # Compile the complete input-source name table, including the parent source.
    for path in (app/'Contents/Resources').glob('*.lproj/InfoPlist.strings'):
        path.write_bytes(plistlib.dumps(names, fmt=plistlib.FMT_BINARY))
PY

ditto "$INSTALLED_APP/Contents/Frameworks/librime.1.dylib" "$APP_PATH/Contents/Frameworks/librime.1.dylib"
if [[ -d "$INSTALLED_APP/Contents/Frameworks/rime-plugins" ]]; then
  ditto "$INSTALLED_APP/Contents/Frameworks/rime-plugins/" "$APP_PATH/Contents/Frameworks/rime-plugins/"
fi
ditto "$INSTALLED_APP/Contents/Frameworks/Sparkle.framework" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

for helper in rime-install rime_deployer rime_dict_manager; do
  if [[ -e "$INSTALLED_APP/Contents/MacOS/$helper" ]]; then
    ditto "$INSTALLED_APP/Contents/MacOS/$helper" "$APP_PATH/Contents/MacOS/$helper"
  fi
done

SOURCE_BASENAMES=(
  BridgingFunctions.swift
  InputSource.swift
  MacOSKeyCodes.swift
  Main.swift
  SquirrelApplicationDelegate.swift
  SquirrelConfig.swift
  SquirrelInputController.swift
  SquirrelPanel.swift
  SquirrelTheme.swift
  SquirrelView.swift
)
SOURCE_FILES=()
for source_basename in "${SOURCE_BASENAMES[@]}"; do
  source_file="$SOURCE_DIR/$source_basename"
  [[ -f "$source_file" ]] || die "upstream source file is missing: $source_file"
  SOURCE_FILES+=("$source_file")
done

EXTRA_SOURCE_FILES=()
if [[ ${EXTRA_SOURCES+x} ]]; then
  EXTRA_SOURCE_VALUES=()
  if [[ -n "$EXTRA_SOURCES" ]]; then
    IFS=': ,' read -r -a EXTRA_SOURCE_VALUES <<< "$EXTRA_SOURCES"
  fi
else
  EXTRA_SOURCE_VALUES=()
  for candidate in "$REPO_ROOT/native/JevCore.swift" "$REPO_ROOT/native/JevIntegration.swift" "$REPO_ROOT/native/JevCommittedContext.swift" "$REPO_ROOT/native/JevLineContext.swift" "$REPO_ROOT/native/JevTrainingSettings.swift" "$REPO_ROOT/native/JevTrainingCapture.swift" "$REPO_ROOT/native/JevTrainingStore.swift" "$REPO_ROOT/native/JevTrainingPreferences.swift" "$REPO_ROOT/native/JevBadge.swift" "$REPO_ROOT/native/JevCandidatePlan.swift" "$REPO_ROOT/native/JevKeychain.swift" "$REPO_ROOT/native/JevLanguageIndicator.swift"; do
    if [[ -f "$candidate" ]]; then
      EXTRA_SOURCE_VALUES+=("$candidate")
    fi
  done
fi
for extra_source in "${EXTRA_SOURCE_VALUES[@]-}"; do
  [[ -n "$extra_source" ]] || continue
  extra_source=$(resolve_repo_path "$extra_source")
  [[ -f "$extra_source" ]] || die "extra Swift source file not found: $extra_source"
  EXTRA_SOURCE_FILES+=("$extra_source")
done
if [[ "${#EXTRA_SOURCE_FILES[@]}" -gt 0 ]]; then
  SOURCE_FILES+=("${EXTRA_SOURCE_FILES[@]}")
fi

for arch in "${ARCHS[@]}"; do
  arch_root="$STAGE_ROOT/$arch"
  mkdir -p "$arch_root/ModuleCache.noindex"
  printf 'Compiling upstream Squirrel (%s) with swiftc %s...\n' "$arch" "$(swiftc --version | head -1)"
  swiftc \
    -target "$arch-apple-macosx$MACOSX_DEPLOYMENT_TARGET" \
    -sdk "$SDKROOT" \
    -swift-version 5 \
    -module-name Squirrel \
    -O \
    -whole-module-optimization \
    -module-cache-path "$arch_root/ModuleCache.noindex" \
    -enable-bare-slash-regex \
    -import-objc-header "$BRIDGING_HEADER" \
    "${RIME_EXTRA_INCLUDE_DIRS[@]}" \
    -I "$RIME_SRC_DIR" \
    -I "$RIME_INCLUDE_DIR" \
    -F "$FRAMEWORK_BUILD_ROOT" \
    "${SOURCE_FILES[@]}" \
    -L "$APP_PATH/Contents/Frameworks" \
    -l rime.1 \
    -framework InputMethodKit \
    -framework UserNotifications \
    -framework QuartzCore \
    -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -o "$arch_root/Squirrel"
done

if [[ "${#ARCHS[@]}" -eq 1 ]]; then
  ditto "$STAGE_ROOT/${ARCHS[0]}/Squirrel" "$APP_PATH/Contents/MacOS/Squirrel"
else
  LIPO_INPUTS=()
  for arch in "${ARCHS[@]}"; do
    LIPO_INPUTS+=("$STAGE_ROOT/$arch/Squirrel")
  done
  lipo -create "${LIPO_INPUTS[@]}" -output "$APP_PATH/Contents/MacOS/Squirrel"
fi

# The ad-hoc signature is deliberately local-only. It proves that the
# resulting bundle is internally signed and does not claim distribution trust.
codesign --force --deep --sign - "$APP_PATH/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP_PATH/Contents/Frameworks/librime.1.dylib"
if [[ -d "$APP_PATH/Contents/Frameworks/rime-plugins" ]]; then
  while IFS= read -r -d '' plugin; do
    codesign --force --sign - "$plugin"
  done < <(find "$APP_PATH/Contents/Frameworks/rime-plugins" -type f -name '*.dylib' -print0)
fi
while IFS= read -r -d '' helper; do
  codesign --force --sign - "$helper"
done < <(find "$APP_PATH/Contents/MacOS" -type f ! -name Squirrel -perm -111 -print0)
codesign --force --sign - --entitlements "$UPSTREAM_DIR/resources/Squirrel.entitlements" "$APP_PATH"

printf '%s\n' 'Verifying architecture, load paths, signature, and non-input-method execution...'
file "$APP_PATH/Contents/MacOS/Squirrel"
lipo -info "$APP_PATH/Contents/MacOS/Squirrel"
otool -L "$APP_PATH/Contents/MacOS/Squirrel" | sed -n '1,16p'
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
"$APP_PATH/Contents/MacOS/Squirrel" --help >/dev/null

printf 'Squirrel probe built successfully: %s\n' "$APP_PATH"
