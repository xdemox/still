# Build and test Still

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
