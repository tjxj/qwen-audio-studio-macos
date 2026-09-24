#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
app="$repo_dir/dist/Qwen Audio Studio.app"
test -d "$app" || { print -u2 'Run scripts/build-app.sh first.'; exit 2; }

scratch="$(mktemp -d /private/tmp/qwen-dmg-test.XXXXXX)"
mountpoint="$scratch/mounted"
cleanup() {
  for attempt in {1..10}; do
    /usr/bin/hdiutil detach -quiet "$mountpoint" 2>/dev/null && break
    /bin/sleep 1
  done
  if ! /sbin/mount | /usr/bin/grep -Fq " on $mountpoint ("; then /bin/rm -R "$scratch"
  else print -u2 "Temporary image still mounted; scratch preserved: $scratch"; fi
}
trap cleanup EXIT

"$repo_dir/scripts/build-dmg.sh" --app "$app" --output "$scratch/Qwen Audio Studio.dmg"
test -s "$scratch/Qwen Audio Studio.dmg"
hdiutil verify "$scratch/Qwen Audio Studio.dmg" >/dev/null
mkdir -p "$mountpoint"
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$scratch/Qwen Audio Studio.dmg" >/dev/null
test -L "$mountpoint/Applications"
test "$(readlink "$mountpoint/Applications")" = /Applications
installed="$mountpoint/Qwen Audio Studio.app"
test -x "$installed/Contents/MacOS/QwenAudioStudioMacApp"
test -f "$installed/Contents/Resources/QwenStudioSerif-Regular.ttf"
test -f "$installed/Contents/Resources/OFL.txt"
test -f "$installed/Contents/Resources/NativeCodecLicenses/opus-1.5.2-COPYING.txt"
test -d "$installed/Contents/Resources/QwenAudioStudioMac_StudioCore.bundle"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed/Contents/Info.plist")" = studio.qwen.audio.mac
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$installed/Contents/Info.plist")" = 14.0
codesign --verify --deep --strict "$installed"
/usr/bin/ditto --norsrc --noextattr "$installed" "$scratch/installed.app"
"$scratch/installed.app/Contents/MacOS/QwenAudioStudioMacApp" --verify-templates | /usr/bin/grep -q 'templates=42; modes=7; eachMode=6'
print 'DMG package acceptance passed: mount, shortcut, resources, strict signature, 42 templates'
