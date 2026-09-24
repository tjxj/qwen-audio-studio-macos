#!/bin/bash
# Tests only: every fixture is a generated 440 Hz sine; no speech or personal data.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Tests/StudioCoreTests/Fixtures/ReferenceAudio
for ext in wav mp3 m4a ogg; do
    codec=pcm_s16le
    case "$ext" in mp3) codec=libmp3lame;; m4a) codec=aac;; ogg) codec=libopus;; esac
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2' \
        -ac 2 -c:a "$codec" "Tests/StudioCoreTests/Fixtures/ReferenceAudio/tone.$ext"
done
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=40' \
    -ac 2 -c:a libopus Tests/StudioCoreTests/Fixtures/ReferenceAudio/long-tone.ogg
