# Contributing to CoShare

Thanks for helping! CoShare is small on purpose: every platform is a thin app around the same simple, documented protocol ([docs/PROTOCOL.md](docs/PROTOCOL.md)). Fixes, translations, new platforms and store releases are all welcome.

## Build and test each app

| Platform | Code | Build | Tests |
|---|---|---|---|
| iPhone, iPad | `iOS/` + `Shared/` | `curl -fsSL https://devehab.github.io/coshare/install-ios.sh \| bash` (or open `CoShare.xcodeproj`, scheme **CoShare iOS**) | `scripts/test-peer.sh`, then `presencetest`, `retentiontest` |
| Mac | `macOS/` + `Shared/` | `scripts/build-mac.sh --install` (Command Line Tools are enough) | same |
| Windows, Linux | `desktop/` (Electron) | `cd desktop && npm ci && npm start` | `npm test` |
| Android | `android/` (Kotlin) | `cd android && ./gradlew assembleDebug` | `./gradlew test` |

Every push runs the full test suite on GitHub Actions. That includes installing the Linux packages on clean Ubuntu, Debian, Fedora and Rocky, and syncing for real between the Swift, Node and Kotlin engines.

## Bring CoShare to a new system

ChromeOS, HarmonyOS, a BSD, a Linux phone, a smartwatch, a terminal tool for servers… all welcome. You don't need anyone's permission and you don't need to change the existing apps:

1. Implement [docs/PROTOCOL.md](docs/PROTOCOL.md). Start with the key, the tag and the [test vector](docs/PROTOCOL.md#test-vectors). Once your code opens that frame, the hard part is done.
2. Discovery: Bonjour (`_coshare._tcp`) plus the direct `hello`, so it works on hotspots too.
3. Clipboard: watch for new copies, send them as `clip`, apply incoming ones, and keep history for the chosen time only.
4. Check it against a real device: `scripts/test-peer.sh` on a Mac gives you a peer that logs everything.
5. Open a pull request in a new top-level folder (e.g. `chromeos/`), with a short README and, if you can, a GitHub Actions job. We'll add it to the website's download section.

Keep the spirit: **local network only, no server, no account, no analytics, end-to-end encrypted.** Pull requests that send data anywhere else won't be merged.

## Publish it on an app store

The [MIT license](LICENSE) lets you publish CoShare on the App Store, Google Play, the Microsoft Store, Flathub, Snapcraft, or anywhere else, under your own developer account. Please:

- keep the copyright notice in the app (an "About" or "Licenses" screen is enough),
- use your own bundle ID and app name. "CoShare by <you>" is fine,
- for the App Store, remove the `audio` background mode. `iOS/BackgroundKeeper.swift` keeps the app alive with silent audio, which is fine for personal installs but not allowed by App Review.

Then **[tell us](https://github.com/Devehab/coshare/issues/new?template=store-release.yml)**: we'll gladly link your store page from [the website](https://devehab.github.io/coshare/), so people can install it in one tap.

## Pull requests

- One change per pull request, with a sentence on why.
- Run the tests of the platform you touched.
- UI text comes in Arabic and English. If you only speak one, write that one and we'll add the other.
