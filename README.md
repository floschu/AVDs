<p align="center"><img alt="AVDs app icon" width="200" src="app/Resources/readme-icon.png"></p>
<h1 align="center">AVDs</h1>
<div align="center">Menu bar app to launch, create, wipe and remove Android™ emulators, and to mirror connected devices with scrcpy.</div>

<br>
<br>

<p align="center"><img alt="AVDs menu bar panel: launching an emulator, mirroring a device, then the New Emulator screen filtered to foldables" width="380" src="app/Resources/demo.png"></p>

## Install

1. Download `AVDs-<version>.dmg` from the [latest release](https://github.com/floschu/AVDs/releases/latest) and open it.
2. Drag AVDs onto Applications.
3. The app isn't signed or notarized, so macOS blocks it on the first launch with "Apple could not verify AVDs". Open System Settings, Privacy & Security, scroll down and click Open Anyway. Or run this once in Terminal: `xattr -dr com.apple.quarantine /Applications/AVDs.app`

AVDs lives in the menu bar. Click its icon to open the panel. Right-click the icon for Refresh, Open at Login, Report an Issue and Quit. On its first launch from Applications, AVDs adds itself to your login items. Turn that off with Open at Login in the same menu.

Click a running emulator's name to bring its window to the front. Hold Option to turn Launch into Cold Boot.

AVDs needs macOS 26 on Apple silicon, the [`android` CLI](https://developer.android.com/tools/agents/android-cli) and the Android SDK. To mirror devices, install [scrcpy](https://github.com/Genymobile/scrcpy) with `brew install scrcpy`. If something is missing, AVDs lists it with the command to install it.

macOS asks whether AVDs may find devices on your local network. That's adb looking for devices with wireless debugging. If you deny it, emulators and USB devices still work.

## Build

```
scripts/build.sh            # builds app/build/AVDs.app
scripts/build.sh --install  # also copies it to /Applications and restarts it
scripts/record-demo.sh      # re-records the animation above with sample data, after UI changes
```

## Release

```
scripts/release.sh 1.1.0
```

The script bumps the version code, builds, commits, tags `v1.1.0`, pushes and creates the GitHub release with a DMG of the app.
Your working tree has to be clean and `gh` logged in. `scripts/release.sh 1.1.0 --dry-run` only builds the DMG.

## License

AVDs is licensed under the [Apache License 2.0](LICENSE).

AVDs doesn't include scrcpy, the Android SDK or the `android` CLI. It runs the copies you installed, under their own terms: [scrcpy](https://github.com/Genymobile/scrcpy) is Apache 2.0, the SDK and CLI come with Google's Android SDK license agreement.

The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the [Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/). Android is a trademark of Google LLC.
