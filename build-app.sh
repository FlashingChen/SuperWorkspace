#!/bin/bash
# 构建可运行的 .app（本地开发签名）。用法：./build-app.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")"
config="${1:-debug}"
app_output="$PWD/.build/app/SuperWorkspace.app"
bundle_id="com.superworkspace.app"
release_version="${SUPERWORKSPACE_RELEASE_VERSION:-}"
build_number="${SUPERWORKSPACE_BUILD_NUMBER:-}"

if [[ -n "$release_version" && ! "$release_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "SUPERWORKSPACE_RELEASE_VERSION must be X.Y.Z." >&2
  exit 1
fi
if [[ -n "$build_number" && ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "SUPERWORKSPACE_BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

python3 scripts/prepare-recorder.py
python3 scripts/prepare-pi.py
python3 scripts/prepare-media.py
swift build -c "$config" --product SuperWorkspace
binary_dir="$(swift build -c "$config" --show-bin-path)"
[[ -f "$binary_dir/SuperWorkspace" ]]

if [[ -e "$app_output" ]] && pgrep -x SuperWorkspace >/dev/null; then
  echo "SuperWorkspace 正在运行，请先退出再替换。" >&2
  exit 1
fi

app="$app_output"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/SuperWorkspace" "$app/Contents/MacOS/SuperWorkspace"
cp Resources/Info.plist "$app/Contents/Info.plist"
swiftc Sources/SuperWorkspace/WorkspaceBrand.swift scripts/generate-icon.swift -o .build/generate-icon
.build/generate-icon .build/Workspace.iconset
iconutil -c icns .build/Workspace.iconset -o "$app/Contents/Resources/Workspace.icns"
ditto Sources/SuperWorkspace/AgentSkills "$app/Contents/Resources/AgentSkills"
ditto .build/PiRuntime "$app/Contents/Resources/PiRuntime"
cp Integration/PiRuntime/run.mjs "$app/Contents/Resources/PiRuntime/run.mjs"
ditto .build/MediaRuntime "$app/Contents/Resources/MediaRuntime"
ditto Integration/RemotionRuntime "$app/Contents/Resources/RemotionRuntime"
for resource in Fonts Onboarding en.lproj zh-Hans.lproj; do
  ditto "dogsc-source/Resources/$resource" "$app/Contents/Resources/$resource"
done
cat Resources/en.lproj/Recorder.strings >> "$app/Contents/Resources/en.lproj/Localizable.strings"
# Host privacy descriptions and application identity take precedence.
rm -f "$app/Contents/Resources/"*.lproj/InfoPlist.strings
cp dogsc-source/LICENSE "$app/Contents/Resources/Recorder-LICENSE"
cp LICENSE "$app/Contents/Resources/SuperWorkspace-LICENSE"
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/SuperWorkspace.entitlements "$app/Contents/Resources/" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app/Contents/Info.plist"
if [[ -n "$release_version" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $release_version" "$app/Contents/Info.plist"
fi
if [[ -n "$build_number" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
fi

python3 scripts/sign-app.py "$app"
printf 'Built: %s\n' "$app"
