<p align="center">
  <img src="assets/icon/icon-graphite.png" width="128" alt="picoTranslator icon">
</p>

<h1 align="center">picoTranslator</h1>

<p align="center">A tiny, no-frills translator for macOS.</p>

<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <img src="assets/screenshots/demo.gif" width="560" alt="Selecting a line of English on a sticky note, and picoTranslator showing its Chinese translation right below the note">
</p>

## Install

Download `picoTranslator.dmg` from the [latest release](https://github.com/encodeous/picoTranslator/releases/latest), open it and drag picoTranslator into Applications. The App Store version is coming soon.

Requires macOS 26 or later.

## picoTranslator is really, really lightweight

- The app is smaller than its own icon!
- It should use about 50MB of memory while idle, and the code is about ~1.5K lines of Swift with no dependencies.
- Everything is built on Apple's native frameworks. It's just a pure translator app, completely free.

## Features

- Select text anywhere on your screen, even in images or apps that don't let you copy it, and see the translation right beside that text.
- Open the translator to type or paste text yourself.
- Automatic language detection, including mixed Chinese, Japanese or Korean with English.
- Hear the text or its translation read aloud, and copy either with one click.

<p align="center">
  <img src="assets/screenshots/settings.png" width="420" alt="picoTranslator settings: Screen Recording permission, translation languages, shortcuts and launch at login">
</p>

## Getting started

picoTranslator lives in the menu bar. The first time it opens, it walks you through:

1. **Screen Recording:** needed to read text from the area you select. macOS asks you to quit and reopen the app after you allow it.
2. **Translation languages:** translations run on your Mac with Apple's models, so download the languages you use in System Settings › General › Language & Region › Translation Languages….
3. **Shortcuts:** press ⌃⌥S to select an area of the screen and translate it, or ⌃⌥T to open the translator and type. You can change both in Settings. Press Esc to close the translator.

The very first screenshot after installing (or after a macOS update) can take up to a minute, while macOS prepares its text recognition model. After that it takes a moment. If your Mac is nearly out of storage, macOS can't keep that model and prepares it again for every screenshot; picoTranslator tells you when this happens.

## Limitations and alternatives

Most of the code in this project was written with AI, and I built it for my own use. If you run into a bug, please [open an issue](https://github.com/encodeous/picoTranslator/issues).

picoTranslator is intentionally small in scope. If you need more, like dictionary lookups, many translation services, AI models or plugins, these are great options:

- [Easydict](https://github.com/tisfeng/Easydict): a free, open source macOS translator and dictionary that can compare results from many services, including AI ones.
- [Pot](https://github.com/pot-app/pot-desktop): a free, open source translator for macOS, Windows and Linux, with plugins for translation, text recognition and text-to-speech.

## Build

Needs the Xcode command line tools.

```bash
./build.sh
open build/picoTranslator.app
```

This makes a size-optimized release build in `build/picoTranslator.app`, signed with your Developer ID or Apple Development certificate if you have one, otherwise ad hoc. To choose the signing identity:

```bash
SIGN_ID="<identity>" ./build.sh
```

To run the tests:

```bash
swift test
```

## License

[GNU Affero General Public License v3.0](LICENSE)
