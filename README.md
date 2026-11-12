# Still for Mac

Source: [xdemox/still](https://github.com/xdemox/still)

Still is a local meeting recorder for Apple silicon Macs with macOS 26 or later. This is an early source release candidate. See [RELEASE.md](RELEASE.md) before distribution. Click the waveform at the right edge of your screen. Use the pin to keep the panel open. If the panel moves out of sight, choose **Show Still** from the waveform in the menu bar.

1. Select **Microphone**, **Mac audio**, or both. Select **Start recording**. macOS asks for access when you use each source for the first time. If you record a call, tell everyone first.
2. Select **Mark** to save the current time. If the live transcript preview is on, Still shows new passages about every ten seconds. Select **Stop & save** to open the meeting and create a transcript from the full recording.
3. Select a time in the transcript to play the recording from that point. Use a passage’s menu to name the speaker or keep the passage as a decision or action.
4. In **Notes**, add your notes and review the suggested decisions and actions. Still looks for common English phrases and shows the original quote. Use **Follow-ups** to set due dates and mark kept actions done.
5. Use **Library** to search titles, notes, speaker labels, and transcripts. Select a match to open the passage. Use a passage's menu to correct its text. Use the meeting menu to export Markdown, text, or audio. You can also delete the audio and keep the notes and transcript.

Use the appearance menu to select Day, Night, or Follow Mac. Open Recordings from the side rail, then select the expand button to view the full Meetings panel.

The meeting search can find matching transcript passages. Its Ask control uses keyword matching and does not generate answers. Highlights are selected transcript passages. Speaker labels come from the audio source or names you assign; Still does not identify each person automatically.

To schedule a recording, select **Schedule recording** on the recording panel. Keep Still open and the Mac awake. The schedule is lost when Still quits. The recording will not start if Still is busy or the Mac wakes more than one minute late. Check the selected audio sources and tell participants before recording.

If you want a meeting countdown, open **Agenda** and select **Connect Calendar**. Still reads upcoming events when you grant access. Select an event to fill in the recording title. You start the recording yourself.

Select **Import audio** to transcribe an existing recording. Use the globe button to choose a language if automatic detection gives the wrong result.

## Privacy

Still ships with the Whisper speech model and runs it on your Mac. It uses the macOS app sandbox with no network permissions. The speech program inherits the same sandbox. Still saves meeting files in its app container. **Mac audio** captures audio from the whole Mac, which can include notification sounds. Still saves audio only.

## Build from source

You need Xcode and CMake. You also need the following two files from the upstream project. This download is part of the build. The finished app runs offline.

```sh
mkdir -p dependencies
curl -fL https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.8.3 -o dependencies/whisper.tar.gz
(cd dependencies && printf '%s  %s\n' 870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a whisper.tar.gz | shasum -a 256 -c)
tar -xzf dependencies/whisper.tar.gz -C dependencies
curl -fL https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin -o dependencies/ggml-base-q5_1.bin
(cd dependencies && printf '%s  %s\n' 422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898 ggml-base-q5_1.bin | shasum -a 256 -c)
cmake -S dependencies/whisper.cpp-1.8.3 -B dependencies/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DWHISPER_CURL=OFF -DGGML_RPC=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF
cmake --build dependencies/build --target whisper-cli --parallel 6
./build.sh dependencies "$PWD/Still.app"
```

The build signs the app for local use with an ad hoc signature. It uses [whisper.cpp](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.8.3) and a [multilingual Whisper model](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-base-q5_1.bin).


## Tests

Build a separate test app. The test uses the bundled sample audio and a separate app identifier. It checks local transcription, playback starting, transcript review, and sandbox network restrictions.

```sh
STILL_TEST_BUILD=1 ./build.sh dependencies "$PWD/Still-test.app"
"$PWD/Still-test.app/Contents/MacOS/Still" --smoke-test
```

Check the app by hand as described in [RELEASE.md](RELEASE.md). The automated playback check does not confirm that audio is audible.

## Licenses

See [third-party notices](ThirdParty/README.md). Still's own source is available under the [MIT License](LICENSE).
