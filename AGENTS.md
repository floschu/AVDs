# AVDs

A macOS menu bar app, written in SwiftUI, that manages Android emulators and connected devices. It doesn't talk to the emulator or adb protocols itself. It runs the command-line tools and parses their output.

## Layout

The top level holds only `app/`, `scripts/`, `README.md`, `LICENSE`, `AGENTS.md`, `CLAUDE.md`, `.gitignore` and `.gitattributes`. Keep it that way.

- `app/Package.swift` is a SwiftPM executable target, macOS 26, Apple silicon only.
- `app/Sources/AVDs/` holds the code. One file per area:
  - `AVDsApp.swift`: the `MenuBarExtra`, the menu bar icon (`BarIcon`), and the right-click menu in `AppDelegate`.
  - `Model.swift`: `Model.shared`, the one `@Observable` state object. Polling, actions and errors live here.
  - `MenuView.swift`: the panel. One list with real devices first, then emulators. It switches to the New Emulator screen.
  - `NewEmulatorScreen.swift`: device catalog with filters, system image picker, name field.
  - `AndroidCLI.swift`: `AVD`, `DeviceKind`, the `android` CLI wrapper, wipe data, and `Shell.run`.
  - `AVDManager.swift`: `SystemImage` (installed and downloadable) and AVD creation through avdmanager.
  - `DeviceCatalog.swift`: parses Android Studio's device definitions.
  - `Devices.swift`: `Tools` (finds the binaries), `ADB`, `PhysicalDevice`, `DeviceTracker`.
  - `Tooltip.swift`: the hover tooltip used everywhere.
  - `RowMenu.swift`: the items of a row's "…" menu and its right-click menu. SwiftUI's `.contextMenu` doesn't open in the menu bar panel, so right clicks on rows go through an AppKit event monitor.
  - `Demo.swift`: demo mode with sample data, see below.
  - `Requirements.swift`: which tools are missing and how to install them. The panel shows them in a tile.
- `app/Resources/`: `Info.plist`, the Icon Composer icon `AVDs.icon`, the menu bar template images, the FLOSCH logo, `demo.png`, the animated PNG in the README, and `readme-icon.png`, the rendered app icon for the README. `build.sh` copies only the files it names into the app.
- `scripts/build.sh` builds `app/build/AVDs.app`. `scripts/release.sh <version name>` releases. See the README.
- `scripts/record-demo.sh` records `app/Resources/demo.png`. `scripts/record-demo.swift` is its helper and does the clicking and capturing.

## Build and check

Run `scripts/build.sh`. It must finish without warnings. Fix new warnings, don't leave them.

To see a change, restart the app. A rebuild doesn't affect the running instance. `osascript -e 'quit app "AVDs"'`, then `open app/build/AVDs.app`.

`AVDS_DEMO=1` shows fixed sample devices and never runs adb, the android CLI, avdmanager or scrcpy. Launch, Stop and Mirror only change the sample state. Its settings live in their own defaults domain. Every new code path that runs a tool needs a `Demo.isOn` check, or demo mode could change the user's real emulators.

`scripts/record-demo.sh` re-records the README animation in demo mode. Run it when the UI changes, not for every release. It takes over mouse and keyboard for about 30 seconds and puts the user's running AVDs back afterwards. It clicks at fixed positions inside the panel, listed in `Spot` in `record-demo.swift`. Update them when the layout moves.

The recording captures only the panel window through ScreenCaptureKit, so the background is transparent. The output is an animated PNG, not a GIF: GIF has no soft edges and keeps old pixels where the panel shrinks. Check the frames on white before committing, for example `ffmpeg -f lavfi -i color=white:s=380x530 -i app/Resources/demo.png -filter_complex "[0][1]overlay=shortest=1,fps=1,tile=7x3" -frames:v 1 contact.png`.

`AVDS_PREVIEW=1 app/build/AVDs.app/Contents/MacOS/AVDs` opens the panel in a normal window. That's easier to screenshot than the menu bar panel, which `screencapture -l <window id>` can also capture while it's open.

There are no unit tests. To check parsing or shell code, compile the source files together with a small `main.swift`, for example `swiftc main.swift app/Sources/AVDs/AndroidCLI.swift app/Sources/AVDs/Devices.swift`, and print what comes back.

The user works on this machine while you do. Before clicking in the UI with synthesized events, check that the panel window is open. A click that misses the panel lands in another app. Don't create, wipe or remove the user's emulators to test. Use a throwaway AVD and delete it afterwards.

## External tools

`Tools` in `Devices.swift` finds them in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and the SDK, on every use, so tools installed while the app runs show up. A GUI app gets no shell `PATH` and no `ANDROID_HOME`, so every process gets `Tools.environment`. `Tools.locateSDK()` falls back to the default SDK path and then to `android info`, run without `ANDROID_HOME` because it echoes that back.

When the app starts depending on another tool, add it to `Requirement.missing` with what it's for and an install command. Don't fail silently or with a raw error.

- `android` CLI: `emulator list --long`, `start`, `stop`, `remove`, `sdk list --all`, `sdk install`.
- `avdmanager` from `cmdline-tools/latest`: creates AVDs, because `android emulator create` only knows six generic profiles. It needs Java. The app uses Android Studio's bundled JBR.
- `adb`: `devices -l`, `track-devices`, `shell getprop`.
- `scrcpy`: mirrors a real device. The app keeps the `Process` to show its state and stop it.
- `ps`: tells whether an emulator runs, and its process ID. Show Window activates that process. For a mirrored device it activates the scrcpy process.

## Things that bit before

- `android emulator list --long` flips between Online and Offline while an emulator boots. Running state comes from the `qemu-system … @<avd>` process. The CLI only supplies the serial.
- AVD names can contain spaces. Parse `emulator list --long` by the header's column positions, never by splitting on whitespace.
- A command can start a background process that keeps the output pipe open, like the adb server. `Shell.run` therefore stops waiting for EOF one second after the process exits. Polling calls pass a `timeout`. Never block on `readDataToEndOfFile`.
- Polling keeps running during long actions such as booting or downloading. Real devices update right away through `adb track-devices`.
- avdmanager leaves Play Store, the hardware keyboard and the GPU off. `AVDManager.create` turns them on in `config.ini`, like Android Studio does. Foldables get their hinge settings from the device definition.
- The device catalog comes from the XML files in `cmdline-tools/latest/lib/sdklib/sdklib.core.jar` plus `~/.android/devices.xml`. Category follows the `tag-id`. Untagged devices of 7" and up count as tablets, unless they fold.
- The Local Network prompt comes from adb's mDNS discovery. `Info.plist` explains it.
- `android sdk install` prints no percentage, not even in a terminal. It prints the archive URL first and downloads into `<sdk>/.sdk/arch/<hash>.part`. `DownloadWatch` asks the server for the size and watches that file. "Unzipping" in the output ends the download.
- The screen can be locked while you work. Then `screencapture`, ScreenCaptureKit and the accessibility tree return nothing useful. Wait for the user to unlock before checking the UI or recording.

## UI rules

- Minimal. Don't show empty sections, headings or controls without a job. App-level actions (refresh, open at login, issues, quit) live in the right-click menu, not in the panel.
- Liquid Glass and system controls: `glassEffect`, `.glass` and `.glassProminent` button styles. Launch and Mirror are prominent blue. Stop is prominent red.
- Use `.tooltip(_:)` from `Tooltip.swift`. `.help` doesn't show in a menu bar panel, and a popover eats the next click.
- Every control needs an accessibility label that names its row, like "Stop Pixel 10". Icon-only buttons need one too.
- Keyboard: the New Emulator screen focuses the search field. Arrows pick a device, Return moves to the name, Return again creates, Escape goes back. Option turns Launch into Cold Boot.
- A row's right-click menu offers the same actions as its buttons and its "…" menu. A disabled menu item needs a reason in the menu.
- Ask before anything that deletes. The question replaces the row's content in place, same tile and same height. A taller tile makes the glass morph and the window jump.
- The menu bar window doesn't animate its size on its own. `MenuView` animates an explicit height while it switches screens and drops it afterwards.
- MenuBarExtra has no right-click menu. `AppDelegate` catches right clicks on the status item with a local event monitor.

## Licensing

AVDs is Apache 2.0. It doesn't bundle scrcpy, the Android SDK or the android CLI, it runs the user's copies. Keep it that way: shipping any of them inside the app would bring their license terms into the DMG.

The icons use the Android robot, which needs the CC BY 3.0 credit line in the README. Don't put "Android" in the app's name, Google only allows "for Android". Google logos and product imagery are trademarks and not covered by that license.

## Git and releases

- Default branch is `develop`, remote `git@github.com:floschu/AVDs.git`.
- When the app icon changes, render `app/Resources/readme-icon.png` again from the built app, for example with `NSWorkspace.shared.icon(forFile:)` at 1024 px, scaled to 512. Not in `build.sh`: every build would rewrite it and `release.sh` needs a clean tree.
- `app/Resources/demo.png` goes through Git LFS (`.gitattributes`). Run `git lfs install --local` once in a fresh clone.
- Don't commit, push or release unless the user asks.
- Version name and code live in `app/Resources/Info.plist`. `scripts/release.sh` sets the name and bumps the code. Don't edit them by hand.
- Version names are semver `MAJOR.MINOR.PATCH`, numbers only. Tags are `v<version name>`.
- Read a file before you overwrite it. The user edits files in this repo too.
