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
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'sine=frequency=220:sample_rate=48000:duration=594' \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=6' \
    -filter_complex '[0:a][1:a]concat=n=2:v=0:a=1[out]' -map '[out]' \
    -ac 2 -c:a libopus -b:a 12k Tests/StudioCoreTests/Fixtures/ReferenceAudio/ten-minute-tone.ogg
