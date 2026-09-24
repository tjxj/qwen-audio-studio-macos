#!/bin/bash
# Development/CI only. The installed app statically links these codecs.
set -euo pipefail
export LC_ALL=C
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
final_prefix="$repo_dir/.build/native-codecs"
if [ -f "$final_prefix/.complete-arm64-macos14-v1" ]; then exit 0; fi
mkdir -p "$final_prefix" "$repo_dir/ThirdParty/Licenses"
work_dir="$(mktemp -d /private/tmp/qwen-codecs.XXXXXX)"
prefix="$work_dir/install"
trap 'rm -R "$work_dir"' EXIT
export MACOSX_DEPLOYMENT_TARGET=14.0
export CC="$(xcrun --find clang)"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
build() {
    local name="$1" url="$2" digest="$3"
    shift 3
    curl --fail --location --retry 3 "$url" -o "$work_dir/$name.tar.gz"
    printf '%s  %s\n' "$digest" "$work_dir/$name.tar.gz" | shasum -a 256 --check
    tar -xzf "$work_dir/$name.tar.gz" -C "$work_dir"
    (cd "$work_dir/$name" && ./configure --prefix="$prefix" --enable-static --disable-shared "$@" && make -j4 && make install) || { tail -100 "$work_dir/$name/config.log"; return 1; }
    cp "$work_dir/$name/COPYING" "$repo_dir/ThirdParty/Licenses/$name-COPYING.txt"
}
build libogg-1.3.6 https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz 83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
build opus-1.5.2 https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1 --disable-extra-programs --disable-doc
export OGG_CFLAGS="-I$prefix/include"
export OGG_LIBS="$prefix/lib/libogg.a"
export OPUS_CFLAGS="-I$prefix/include/opus"
export OPUS_LIBS="$prefix/lib/libopus.a"
# Configure uses shell-expanded flags. A symlink avoids whitespace in vault paths.
ln -s "$prefix" "$work_dir/deps"
export OGG_CFLAGS="-I$work_dir/deps/include"
export OGG_LIBS="$work_dir/deps/lib/libogg.a"
export OPUS_CFLAGS="-I$work_dir/deps/include/opus"
export OPUS_LIBS="$work_dir/deps/lib/libopus.a"
build opusfile-0.12 https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz 118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b --disable-http --disable-examples --disable-doc
ditto "$prefix" "$final_prefix"
touch "$final_prefix/.complete-arm64-macos14-v1"
