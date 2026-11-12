#!/bin/bash
set -euo pipefail

source_dir=$(cd "$(dirname "$0")" && pwd)
if [[ $# != 2 ]]; then
    echo "Usage: $0 /path/to/build-dependencies /path/to/Still.app" >&2
    exit 2
fi
deps=$(cd "$1" && pwd)
app=$2
model="$deps/ggml-base-q5_1.bin"
whisper="$deps/build/bin/whisper-cli"
if [[ ! -f "$model" || ! -x "$whisper" ]]; then
    echo 'Build dependencies are missing. Follow the steps in README.md.' >&2
    exit 2
fi

if [[ -e "$app" ]]; then
    echo "Move the previous build first: $app" >&2
    exit 2
fi
printf '%s  %s\n' 422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898 "$model" | shasum -a 256 -c

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
bundle="$build_dir/Still.app"
contents="$bundle/Contents"
resources="$contents/Resources"
mkdir -p "$contents/MacOS" "$resources" "$build_dir/Still.iconset"

xcrun swift -module-cache-path "$build_dir/cache" "$source_dir/Icon.swift" "$build_dir/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$build_dir/icon.png" --out "$build_dir/Still.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$build_dir/icon.png" --out "$build_dir/Still.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$build_dir/Still.iconset" --output "$resources/Still.icns"

build_flags=(-O)
if [[ ${STILL_TEST_BUILD:-0} == 1 ]]; then
    build_flags=(-D DEBUG -Onone)
    cp "$deps/whisper.cpp-1.8.3/samples/jfk.wav" "$resources/jfk.wav"
fi
cp "$source_dir/Info.plist" "$contents/Info.plist"
if [[ ${STILL_TEST_BUILD:-0} == 1 ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.still.meetings.test' "$contents/Info.plist"
fi
xcrun swiftc -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path "$build_dir/cache" \
    "${build_flags[@]}" "$source_dir/Still.swift" "$source_dir/Library.swift" "$source_dir/Recording.swift" \
    "$source_dir/Transcription.swift" "$source_dir/Review.swift" "$source_dir/Agenda.swift" -o "$contents/MacOS/Still"
cp "$whisper" "$contents/MacOS/whisper-cli"
cp "$model" "$resources/ggml-base-q5_1.bin"
cp "$source_dir/ThirdParty/"*-LICENSE.txt "$resources/"
cp "$source_dir/ThirdParty/README.md" "$resources/ThirdParty-NOTICES.txt"

codesign --force --sign - --entitlements "$source_dir/Helper.entitlements" "$contents/MacOS/whisper-cli"
codesign --force --sign - --entitlements "$source_dir/Still.entitlements" "$bundle"
codesign --verify --deep --strict "$bundle"
if [[ -e "$app" ]]; then
    echo "Move the previous build first: $app" >&2
    exit 2
fi
mkdir -p "$(dirname "$app")"
ditto "$bundle" "$app"
