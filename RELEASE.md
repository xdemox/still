# Release checklist

This folder is a source release candidate. It is not a signed public app release.

## Before publishing source

- Confirm the copyright attribution in LICENSE. The third-party licenses cover their own components.
- Confirm the rights to all source, artwork, name, and other assets. Review any third-party product references and any material copied from other products. This package does not establish provenance or grant those rights.
- Review the final files and repository history for private information. Review commits and attachments as well as the current files.
- Provide a contact and a way to report security issues.

## Before distributing an app

- Choose a bundle identifier under your control and a version number. Changing the identifier changes the app's sandbox container. Plan and test migration before replacing an existing installation.
- Build and test on supported Apple silicon Macs. Test microphone and Mac audio permissions, import, playback, transcription, calendar access, scheduling, and both themes.
- Test recording interruptions, sleep, full disk, permission denial, and recovery. Test with a clean user account.
- Sign the app and its helper using an Apple Developer ID and the correct entitlements. Enable the hardened runtime. Submit the signed app for Apple notarization and staple the result. Verify the final downloaded package with Gatekeeper on a clean Mac. The included build script uses an ad hoc signature for local testing only.
- Include all third-party notices in the distributed app. Review the licenses and the exact dependency versions used for the release.
- Document support, privacy, consent, updates, and known limitations. Do not promise cloud services or automatic speaker identification.

Apple's guidance: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
