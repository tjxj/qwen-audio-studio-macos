# Native Ogg Opus decoder

`scripts/build-native-codecs.sh` builds libogg 1.3.6, opus 1.5.2 and opusfile 0.12
from official Xiph release archives. The script pins and verifies each SHA256,
sets an arm64 macOS 14 deployment target, disables shared libraries and HTTP,
and stages static archives under the ignored `.build/native-codecs` directory.
Run it before `swift build` or `swift test`; `scripts/build-app.sh` calls it
automatically. A macOS SDK and compiler are required for development.

The installed application includes the codec machine code in its executable.
It does not require Homebrew, downloaded libraries, command line decoders, a
network service, or a codec installation. The three upstream copyright/license
files under `Licenses` are copied into the signed app's Resources directory.
libogg and opus use BSD-style licenses; opusfile uses a BSD-style license.

`COpusBridge` uses opusfile's local-file API and streams bounded stereo chunks.
AVAudioConverter mixes/resamples into fixed output buffers and a streaming writer
emits 24 kHz mono PCM16 WAV. No full-source float array is retained.
The reference-file pipeline rejects malformed streams and chained Ogg links.

Synthetic test fixtures can be regenerated with
`bash scripts/make-reference-fixtures.sh`. This development-only script uses
ffmpeg to encode 440 Hz tones; it is never called by the app. The 40-second
Opus fixture checks that conversion retains the tail of a long source. A second
600-second fixture drives `scripts/verify-reference-memory.sh`, which measures
the standalone app process's peak RSS (including frameworks) against 160 MiB and
checks its final six seconds. Only synthetic tones are used.
