#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
app="$repo_dir/dist/Qwen Audio Studio.app"
output="$repo_dir/dist/Qwen Audio Studio-macOS14-AppleSilicon.dmg"
provided_app=false
replace=false
while (( $# )); do
  case "$1" in
    --app) (( $# >= 2 )) || { print -u2 'Missing --app value'; exit 2; }; app="$2"; provided_app=true; shift 2 ;;
    --output) (( $# >= 2 )) || { print -u2 'Missing --output value'; exit 2; }; output="$2"; shift 2 ;;
    --replace) replace=true; shift ;;
    *) print -u2 "Unknown argument: $1"; exit 2 ;;
  esac
done

if ! $provided_app; then
  "$repo_dir/scripts/build-app.sh"
fi
[[ -d "$app" && -x "$app/Contents/MacOS/QwenAudioStudioMacApp" ]] || {
  print -u2 'Signed app bundle is missing.'; exit 2
}
[[ "$output" == *.dmg ]] || { print -u2 'Output must have a .dmg extension.'; exit 2; }
if [[ -e "$output" && "$replace" == false ]]; then
  print -u2 'Output exists. Supply --replace to overwrite this exact DMG.'; exit 2
fi

# Stage away from iCloud to avoid synced Finder metadata invalidating a strict signature.
scratch="$(mktemp -d /private/tmp/qwen-studio-dmg.XXXXXX)"
mountpoint="$scratch/mounted"
is_mounted() { /sbin/mount | /usr/bin/grep -Fq " on $mountpoint ("; }
detach_volume() {
  local attempt
  for attempt in {1..10}; do
    if ! is_mounted; then return 0; fi
    /usr/bin/hdiutil detach -quiet "$mountpoint" 2>/dev/null && return 0
    /bin/sleep 1
  done
  ! is_mounted
}
cleanup() {
  if detach_volume; then /bin/rm -R "$scratch"
  else print -u2 "Temporary image is still mounted; scratch preserved: $scratch"; fi
}
trap cleanup EXIT
payload="$scratch/payload"
mkdir -p "$payload"
/usr/bin/ditto --norsrc --noextattr "$app" "$payload/Qwen Audio Studio.app"
/usr/bin/codesign --force --sign - "$payload/Qwen Audio Studio.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$payload/Qwen Audio Studio.app"
"$payload/Qwen Audio Studio.app/Contents/MacOS/QwenAudioStudioMacApp" --verify-templates
/bin/ln -s /Applications "$payload/Applications"

/usr/bin/hdiutil create -srcfolder "$payload" -volname 'Qwen Audio Studio' \
  -format UDZO -fs HFS+ "$scratch/release.dmg"
/usr/bin/hdiutil verify "$scratch/release.dmg"
mkdir -p "$mountpoint"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$scratch/release.dmg"
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || {
  print -u2 'DMG Applications shortcut missing.'; exit 1
}
mounted_app="$mountpoint/Qwen Audio Studio.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$mounted_app"
[[ -f "$mounted_app/Contents/Resources/QwenStudioSerif-Regular.ttf" && \
   -f "$mounted_app/Contents/Resources/QwenAudioStudioMac_StudioCore.bundle/templates.json" && \
   -f "$mounted_app/Contents/Resources/NativeCodecLicenses/opus-1.5.2-COPYING.txt" ]] || {
  print -u2 'DMG resources incomplete.'; exit 1
}
detach_volume || { print -u2 'Could not detach verified temporary image.'; exit 1; }

mkdir -p "${output:h}"
if [[ -e "$output" && "$replace" == true ]]; then
  # Exact named output was explicitly selected for replacement.
  /bin/rm "$output"
fi
/usr/bin/ditto --norsrc --noextattr "$scratch/release.dmg" "$output"
/usr/bin/hdiutil verify "$output"
print "Local ad-hoc signed DMG (not notarized): $output"
