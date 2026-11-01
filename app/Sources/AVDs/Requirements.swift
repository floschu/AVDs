import Foundation

/// A tool the app needs that isn't installed, with what it's for and how to get it.
struct Requirement: Identifiable, Equatable {
    enum Fix: Equatable {
        case command(String)
        case link(String, URL)
    }

    let id: String
    let title: String
    let detail: String
    let fix: Fix

    /// Everything missing right now. Only file checks, cheap enough to run on every refresh.
    /// scrcpy only counts while a device is connected, since only mirroring needs it.
    static func missing(deviceConnected: Bool) -> [Requirement] {
        var missing: [Requirement] = []
        if Tools.android == nil {
            missing.append(Requirement(
                id: "android", title: "Android CLI",
                detail: "Lists, starts and stops emulators.",
                fix: .link("Install guide", URL(string: "https://developer.android.com/tools/agents/android-cli")!)))
        }
        if Tools.adb == nil {
            missing.append(Requirement(
                id: "adb", title: "Platform tools",
                detail: "adb finds connected devices.",
                fix: .command("android sdk install platform-tools")))
        }
        if Tools.emulator == nil {
            missing.append(Requirement(
                id: "emulator", title: "Android Emulator",
                detail: "Runs the emulators.",
                fix: .command("android sdk install emulator")))
        }
        if AVDManager.executable == nil {
            missing.append(Requirement(
                id: "cmdline-tools", title: "Command-line tools",
                detail: "Create emulators and provide the device list.",
                fix: .command("android sdk install cmdline-tools/latest")))
        } else if AVDManager.javaHome == nil {
            missing.append(Requirement(
                id: "java", title: "Java",
                detail: "The command-line tools need it to create emulators.",
                fix: .command("brew install --cask temurin")))
        }
        if deviceConnected && Tools.scrcpy == nil {
            missing.append(Requirement(
                id: "scrcpy", title: "scrcpy",
                detail: "Mirrors connected devices.",
                fix: .command("brew install scrcpy")))
        }
        return missing
    }
}
