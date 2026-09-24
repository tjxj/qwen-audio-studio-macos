#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/qwen-native-module-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/private/tmp/qwen-native-module-cache}"

swift build -c release --disable-sandbox \
  --cache-path /private/tmp/qwen-swiftpm-cache \
  -Xswiftc -module-cache-path \
  -Xswiftc "$SWIFT_MODULE_CACHE_PATH"

staging_dir="$(mktemp -d /private/tmp/qwen-studio-app.XXXXXX)"
trap '/bin/rm -R "$staging_dir"' EXIT
app_dir="$staging_dir/Qwen Audio Studio.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$repo_dir/.build/release/QwenAudioStudioMacApp" "$app_dir/Contents/MacOS/"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Resources/Fonts/QwenStudioSerif-Regular.ttf" "$app_dir/Contents/Resources/"
cp "$repo_dir/Resources/Fonts/OFL.txt" "$app_dir/Contents/Resources/"

codesign --force --sign - "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --verify --verbose=2 "$app_dir"

dist_app="$repo_dir/dist/Qwen Audio Studio.app"
mkdir -p "$repo_dir/dist"
if [[ "$dist_app" == "$repo_dir/dist/Qwen Audio Studio.app" && -d "$dist_app" ]]; then
  /bin/rm -R "$dist_app"
fi
/usr/bin/ditto --norsrc --noextattr "$app_dir" "$dist_app"
print "Built: $dist_app"
