import Foundation

/// A real device connected over USB or Wi-Fi, from `adb devices -l`.
struct PhysicalDevice: Identifiable, Hashable {
    let id: String // serial
    let state: String
    let model: String
    let usb: Bool
    var androidVersion: String?

    var isReady: Bool { state == "device" }

    var stateLabel: String {
        switch state {
        case "device": usb ? "USB" : "Wi-Fi"
        case "unauthorized": "Allow USB debugging on the device"
        case "offline": "Offline"
        default: state.capitalized
        }
    }
}

/// Finds the command-line tools. Everything is looked up on each use, so a tool installed while
/// the app runs is picked up without a restart.
enum Tools {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The Android SDK. A GUI app doesn't get ANDROID_HOME from the shell, so `locateSDK()` also
    /// asks the android CLI when the SDK isn't in the default place.
    nonisolated(unsafe) static var sdk = configuredSDK

    private static var configuredSDK: String {
        let env = ProcessInfo.processInfo.environment
        return env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"] ?? "\(home)/Library/Android/sdk"
    }

    /// When the configured SDK doesn't exist, tries the default location, then asks `android info`.
    /// That runs without ANDROID_HOME, which it would just echo back.
    static func locateSDK() async {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: sdk) else { return }
        let standard = "\(home)/Library/Android/sdk"
        if fm.fileExists(atPath: standard) {
            sdk = standard
            return
        }
        var env = environment
        env["ANDROID_HOME"] = nil
        env["ANDROID_SDK_ROOT"] = nil
        guard let android,
              let info = try? await Shell.run(android, ["info"], environment: env, timeout: .seconds(10)) else { return }
        let path = info.split(separator: "\n")
            .first { $0.hasPrefix("sdk:") }
            .map { $0.dropFirst(4).trimmingCharacters(in: .whitespaces) }
        if let path, FileManager.default.fileExists(atPath: path) { sdk = path }
    }

    static var path: String {
        "\(home)/.local/bin:\(sdk)/platform-tools:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    static func find(_ name: String, extra: [String] = []) -> URL? {
        (extra + ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    static var android: URL? { find("android") }
    static var adb: URL? { find("adb", extra: ["\(sdk)/platform-tools/adb"]) }
    static var scrcpy: URL? { find("scrcpy") }
    static var emulator: URL? {
        let path = "\(sdk)/emulator/emulator"
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        env["ANDROID_HOME"] = sdk
        if let adb { env["ADB"] = adb.path } // scrcpy uses the SDK adb, so both share one server
        return env
    }
}

enum ADB {
    static func devices() async throws -> [PhysicalDevice] {
        guard let adb = Tools.adb else { return [] }
        let output = try await Shell.run(adb, ["devices", "-l"], timeout: .seconds(15))
        return output
            .split(separator: "\n")
            .dropFirst() // "List of devices attached"
            .compactMap { line in
                let cols = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard cols.count >= 2, !cols[0].hasPrefix("emulator-") else { return nil }
                let fields = Dictionary(cols.dropFirst(2).compactMap { field -> (String, String)? in
                    let kv = field.split(separator: ":", maxSplits: 1)
                    return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
                }, uniquingKeysWith: { a, _ in a })
                return PhysicalDevice(
                    id: cols[0],
                    state: cols[1],
                    model: (fields["model"] ?? cols[0]).replacingOccurrences(of: "_", with: " "),
                    usb: fields["usb"] != nil
                )
            }
    }

    static func androidVersion(_ serial: String) async -> String? {
        guard let adb = Tools.adb,
              let v = try? await Shell.run(adb, ["-s", serial, "shell", "getprop", "ro.build.version.release"],
                                           timeout: .seconds(5)),
              !v.isEmpty else { return nil }
        return "Android \(v)"
    }
}

/// Runs `adb track-devices`, which prints a line whenever a device connects, disconnects or
/// changes state. Restarts it when it ends, for example after the adb server restarted.
@MainActor
final class DeviceTracker {
    private var process: Process?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        start()
    }

    private func start() {
        guard let adb = Tools.adb else { return }
        let process = Process()
        process.executableURL = adb
        process.arguments = ["track-devices"]
        process.environment = Tools.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.onChange() }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self?.start()
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            self.process = nil
        }
    }
}
