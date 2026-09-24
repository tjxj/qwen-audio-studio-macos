#!/bin/zsh
set -euo pipefail
repo_dir="${0:A:h:h}"
for size in 1120 1280 1400 1600; do
  for appearance in light dark; do
    image="$repo_dir/docs/qa/task10/creation-$appearance-$size.png"
    test -f "$image" || { print -u2 "Missing native window capture: $appearance $size"; exit 1; }
    expected_width=$((size * 2))
    actual_width="$(sips -g pixelWidth "$image" | awk '/pixelWidth/ {print $2}')"
    test "$actual_width" = "$expected_width" || { print -u2 "Wrong 2x width for $image"; exit 1; }
  done
done
print 'Four native window widths, light/dark, 2x captures verified'
