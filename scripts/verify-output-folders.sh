#!/bin/zsh
set -euo pipefail

# Run from a native macOS desktop session with access to AppKit and
# ScopedBookmarksAgent. Every new file-operation fixture is a temporary UUID.
repo_dir="${0:A:h:h}"
cd "$repo_dir"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/qwen-native-module-cache}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-/private/tmp/qwen-native-module-cache}"
test_args=(--no-parallel --disable-sandbox --cache-path /private/tmp/qwen-swiftpm-cache
  -Xswiftc -module-cache-path -Xswiftc "$SWIFT_MODULE_CACHE_PATH")

# Explicit serialization also protects existing MainActor debounce assertions
# from competing AppKit setup. System-panel initialization competes with suites.
# Keep the real panel
# test as a required second phase, with its existing 25-second process timeout.
QWEN_TEST_OPEN_PANEL=0 swift test "${test_args[@]}"
QWEN_TEST_OPEN_PANEL=1 swift test --filter realDialogCancelKeepsExistingSelection "${test_args[@]}"
scripts/build-app.sh
