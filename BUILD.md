# Build and test Still

Use an Apple silicon Mac with Xcode and Swift 6.2 or later. The app requires macOS 26 or later.

## Prepare the speech model

Run these commands from the repository folder. This step uses the internet to fetch the pinned FluidAudio dependency and the Parakeet model. No meeting audio is sent.

```sh
mkdir -p dependencies
swift build --package-path SpeechHelper -c release --product prepare-parakeet
SpeechHelper/.build/release/prepare-parakeet "$PWD/dependencies/parakeet-tdt-0.6b-v3"
```

The preparation tool downloads the current Core ML conversion of Parakeet TDT v3. Keep a copy of the prepared model folder for repeat builds. FluidAudio's source revision is pinned in SpeechHelper/Package.swift and Package.resolved.

## Build

```sh
./build.sh dependencies "$PWD/Still.app"
```

The script bundles the prepared model and signs the app for local use. The finished app has no network permission. Its speech helper loads the bundled models through FluidAudio's local-only loader. Missing files cause an error; the app cannot download replacements.

Parakeet detects the language automatically. The globe menu provides a writing-script hint, such as Latin or Cyrillic, through the selected language. This hint does not force a language. See the [model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) for supported languages.

## Tests

Fetch the public sample audio, then build a separate test app:

```sh
curl -fL https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.8.3/samples/jfk.wav -o dependencies/jfk.wav
STILL_TEST_BUILD=1 ./build.sh dependencies "$PWD/Still-test.app"
"$PWD/Still-test.app/Contents/MacOS/Still" --smoke-test
```

Tests use a separate app identifier. They check local transcription, live preview, timestamps, microphone mute, playback starting, transcript review, and sandbox network restrictions. The playback check does not confirm that audio is audible.

The helper loads models for each transcription job. This keeps model memory separate from the recording app, but adds loading time to each live preview update.

Use [RELEASE.md](RELEASE.md) for the checks needed before public app distribution.
