import Foundation

/// `AVDS_DEMO=1` shows fixed sample devices for screenshots and the README animation
/// (`scripts/record-demo.sh`). It never runs adb, the android CLI, avdmanager or scrcpy. Launch,
/// Stop and Mirror only change the sample state. Settings go to their own defaults domain, so a
/// recording doesn't change the user's filters.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["AVDS_DEMO"] == "1"

    static let defaults: UserDefaults = {
        let name = "at.florianschuster.avds.demo"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name) // every demo run starts the same
        return defaults
    }()

    static let devices = [
        PhysicalDevice(id: "DEMO0001", state: "device", model: "Pixel 9 Pro", usb: true, androidVersion: "Android 16"),
    ]

    static let downloadable = [
        SystemImage(platform: "android-37.0", tag: "google_apis_playstore", abi: "arm64-v8a", installed: false),
        SystemImage(platform: "android-37.0", tag: "google_apis", abi: "arm64-v8a", installed: false),
        SystemImage(platform: "android-36", tag: "android-wear", abi: "arm64-v8a", installed: false),
    ]

    static let avds = [
        demoAVD("Pixel_10_API_37", "Pixel 10", "android-37.0", .phone, "Google Play"),
        demoAVD("Pixel_Tablet_API_37", "Pixel Tablet", "android-37.0", .tablet, "Google Play", serial: "emulator-5554"),
        demoAVD("Pixel_9_Pro_Fold_API_36", "Pixel 9 Pro Fold", "android-36", .foldable, "Google Play"),
        demoAVD("Wear_OS_Round_API_36", "Wear OS Round", "android-36", .wear, "Wear OS 6.0"),
    ]

    private static func demoAVD(_ id: String, _ name: String, _ api: String, _ kind: DeviceKind,
                                _ variant: String, serial: String? = nil) -> AVD {
        var avd = AVD(id: id, api: api, status: serial == nil ? "Offline" : "Online", serial: serial,
                      displayName: name, kind: kind, variant: variant)
        avd.demoRunning = serial != nil
        return avd
    }

    static func running(_ avd: AVD, serial: String?) -> AVD {
        var copy = AVD(id: avd.id, api: avd.api, status: serial == nil ? "Offline" : "Online", serial: serial,
                       displayName: avd.displayName, kind: avd.kind, variant: avd.variant)
        copy.demoRunning = serial != nil
        return copy
    }
}

extension Model {
    func startDemo() {
        avds = Demo.avds
        devices = Demo.devices
        downloadable = Demo.downloadable
        loaded = true
    }

    /// Plays a download when the image isn't installed, then adds the emulator to the list.
    func demoCreate(_ device: DeviceDefinition, image: SystemImage, name: String) async {
        if !image.installed {
            let total: Int64 = 1_450_000_000
            for step in 0...12 {
                creatingProgress = .downloading(received: total * Int64(step) / 12, total: total)
                try? await Task.sleep(for: .milliseconds(250))
            }
            creatingProgress = .unpacking
            try? await Task.sleep(for: .seconds(1))
            creatingProgress = nil
        }
        try? await Task.sleep(for: .seconds(1))
        func id(_ name: String) -> String { String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" }) }
        var unique = name
        var n = 2
        while avds.contains(where: { $0.id == id(unique) }) {
            unique = "\(name) (\(n))"
            n += 1
        }
        avds.append(AVD(id: id(unique), api: image.platform, status: "Offline", serial: nil, displayName: unique,
                        kind: DeviceKind(tag: image.tag, device: device.id, name: device.name),
                        variant: image.hasPlayStore ? "Google Play" : nil))
    }

    /// Plays an emulator action on the sample data with a short delay, like the real one.
    func demoPerform(_ avd: AVD, _ kind: Activity) async {
        activity[avd.id] = kind
        try? await Task.sleep(for: .seconds(kind == .starting ? 2 : 1))
        activity[avd.id] = nil
        guard let i = avds.firstIndex(where: { $0.id == avd.id }) else { return }
        switch kind {
        case .starting:
            let used = Set(avds.compactMap(\.serial))
            let serial = (0...20).map { "emulator-\(5554 + $0 * 2)" }.first { !used.contains($0) }
            avds[i] = Demo.running(avd, serial: serial)
        case .stopping: avds[i] = Demo.running(avd, serial: nil)
        case .removing: avds.remove(at: i)
        case .wiping: break
        }
    }
}
