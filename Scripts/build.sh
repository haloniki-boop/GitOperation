#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_project_dir="$project_dir"
derived_data_path="$project_dir/build"
temporary_root=""

cleanup() {
  if [[ -n "$temporary_root" && "$temporary_root" == "${TMPDIR%/}/GitOperationBuild."* ]]; then
    rm -rf -- "$temporary_root"
  fi
}
trap cleanup EXIT

if ! xcodebuild -version >/dev/null 2>&1; then
  xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
  if [[ -d "$xcode_developer_dir" ]]; then
    export DEVELOPER_DIR="$xcode_developer_dir"
  else
    print -u2 "完全版のXcodeが必要です。App StoreからXcodeをインストールしてください。"
    exit 1
  fi
fi

# Xcodeのビルドサービスは外部ボリューム上のbuild.dbで停止する場合があるため、
# プロジェクトが /Volumes 配下なら内部の一時領域でビルドする。
if [[ "$project_dir" == /Volumes/* ]]; then
  temporary_root="$(mktemp -d "${TMPDIR%/}/GitOperationBuild.XXXXXX")"
  build_project_dir="$temporary_root/source"
  derived_data_path="$temporary_root/DerivedData"
  mkdir -p "$build_project_dir"
  rsync -a \
    --exclude '.git/' \
    --exclude '.build/' \
    --exclude 'build/' \
    --exclude '.swiftpm/' \
    --exclude '.DS_Store' \
    --exclude '._*' \
    --exclude '*.textClipping' \
    --exclude 'xcuserdata/' \
    --exclude '*.xcuserstate' \
    "$project_dir/" "$build_project_dir/"
fi

xcodebuild \
  -quiet \
  -project "$build_project_dir/GitOperation.xcodeproj" \
  -scheme GitOperation \
  -configuration Release \
  -derivedDataPath "$derived_data_path" \
  CODE_SIGNING_ALLOWED=NO \
  build

built_app="$derived_data_path/Build/Products/Release/GitOperation.app"
if [[ ! -x "$built_app/Contents/MacOS/GitOperation" ]]; then
  print -u2 "アプリ実行ファイルが生成されませんでした。"
  exit 1
fi

# CODE_SIGNING_ALLOWED=NO leaves the Finder Sync extension linker-signed and
# drops its sandbox/shared-preference entitlements. Finder then rejects or
# isolates the extension, so context menus and status badges cannot work.
# Sign the nested extension first with its entitlements, then seal the host app.
finder_extension="$built_app/Contents/PlugIns/GitFinderExtension.appex"
finder_entitlements="$build_project_dir/GitFinderExtension/GitFinderExtension.entitlements"
if [[ ! -x "$finder_extension/Contents/MacOS/GitFinderExtension" ]]; then
  print -u2 "Finder拡張機能が生成されませんでした。"
  exit 1
fi
/usr/bin/codesign \
  --force \
  --sign - \
  --entitlements "$finder_entitlements" \
  "$finder_extension"
/usr/bin/codesign --force --sign - "$built_app"
/usr/bin/codesign --verify --deep --strict "$built_app"

if [[ -n "$temporary_root" ]]; then
  output_app="${TMPDIR%/}/GitOperationRelease/GitOperation.app"
else
  output_app="$built_app"
fi
if [[ "$built_app" != "$output_app" ]]; then
  mkdir -p "${output_app:h}"
  rm -rf -- "$output_app"
  cp -R "$built_app" "$output_app"
fi

print "ビルド完了: $output_app"
