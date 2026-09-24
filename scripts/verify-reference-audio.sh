#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
qa_root="${TMPDIR%/}/$(uuidgen)"
mkdir "$qa_root"
trap 'rm -R "$qa_root"' EXIT
cp Tests/StudioCoreTests/Fixtures/ReferenceAudio/tone.* "$qa_root/"
"dist/Qwen Audio Studio.app/Contents/MacOS/QwenAudioStudioMacApp" "--verify-reference-audio-root=$qa_root"
mkdir -p docs/qa/reference-audio
cp "$qa_root/"*.png "$qa_root/reference-audio-checks.txt" docs/qa/reference-audio/
