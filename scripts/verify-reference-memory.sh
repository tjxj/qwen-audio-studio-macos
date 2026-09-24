#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
qa_root="${TMPDIR%/}/$(uuidgen)"
mkdir "$qa_root"
trap 'rm -R "$qa_root"' EXIT
cp Tests/StudioCoreTests/Fixtures/ReferenceAudio/ten-minute-tone.ogg "$qa_root/"
"dist/Qwen Audio Studio.app/Contents/MacOS/QwenAudioStudioMacApp" "--verify-reference-memory-root=$qa_root"
mkdir -p docs/qa/reference-audio
cp "$qa_root/reference-memory-checks.txt" docs/qa/reference-audio/
