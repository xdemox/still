# Still for Mac

A local meeting recorder for Apple silicon Macs running macOS 26 or later.

## Features

- Record your microphone, Mac audio, or both.
- Transcribe recordings on your Mac with Whisper.
- Search meetings and jump to timestamped passages.
- Add notes, review actions, and mark important moments.
- Filter meetings by date, topic, or speaker label.
- Use a compact side panel or expand it into the Meetings view.
- Choose a day or night theme, or follow your Mac’s appearance.

## Privacy

Audio and transcripts stay on your Mac. The app runs in the macOS sandbox without network permissions. Tell participants before recording.

## Build

You need Xcode and CMake. Follow the [build and test instructions](BUILD.md).

This is an early version. Search uses keyword matching, highlights select transcript passages, and speaker labels use audio sources or names you assign. Scheduled recording requires Still to stay open and your Mac to stay awake.

See the [release checklist](RELEASE.md) for distribution requirements.

## License

[MIT](LICENSE). Third-party components have [their own notices](ThirdParty/README.md).
