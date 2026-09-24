#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
dmg="${1:-$repo_dir/dist/Qwen Audio Studio-macOS14-AppleSilicon.dmg}"
[[ -f "$dmg" ]] || { print -u2 'DMG not found.'; exit 2; }
scratch="$(mktemp -d /private/tmp/qwen-install-qa.XXXXXX)"
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
mkdir -p "$mountpoint" "$scratch/Applications"
hdiutil verify "$dmg" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "$mountpoint" "$dmg" >/dev/null
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || exit 1
installed="$scratch/Applications/Qwen Audio Studio.app"
/usr/bin/ditto --norsrc --noextattr "$mountpoint/Qwen Audio Studio.app" "$installed"
codesign --verify --deep --strict "$installed"
plutil -lint "$installed/Contents/Info.plist" >/dev/null
test -f "$installed/Contents/Resources/QwenStudioSerif-Regular.ttf"
test -f "$installed/Contents/Resources/QwenAudioStudioMac_StudioCore.bundle/templates.json"
test -f "$installed/Contents/Resources/NativeCodecLicenses/opus-1.5.2-COPYING.txt"
binary="$installed/Contents/MacOS/QwenAudioStudioMacApp"
"$binary" --verify-templates | /usr/bin/grep -q 'templates=42; modes=7; eachMode=6'
data_root="$scratch/synthetic-data"
for run in first second; do
  "$binary" --capture-native-window --capture-ui="$scratch/capture-$run" \
    --capture-task9-root="$data_root"
  test -s "$scratch/capture-$run/creation-light-1120.png"
  test -s "$data_root/studio.sqlite"
  count="$(/usr/bin/sqlite3 "$data_root/studio.sqlite" 'SELECT COUNT(*) FROM projects;')"
  if [[ "$run" == first ]]; then
    first_count="$count"
    (( first_count >= 7 )) || exit 1
  else
    (( count > first_count )) || { print -u2 'Installed app did not reopen and retain its SQLite data.'; exit 1; }
  fi
done
print "Temporary Applications install verified: strict ad-hoc signature, resources, 42 templates, two native UI launches, persisted SQLite project count $first_count -> $count."
print 'System /Applications and production App Support were not changed.'
