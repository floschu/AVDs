import AppKit
import Observation

enum Activity: Equatable {
    case starting, stopping, removing, wiping
}

@MainActor
@Observable
final class Model {
    /// The one model the app uses. The right-click menu needs it outside of SwiftUI.
    static let shared = Model()

    var avds: [AVD] = []
    var devices: [PhysicalDevice] = []
    var catalog: [DeviceDefinition] = []
    /// False until the device catalog was read, whether or not that found anything.
    var catalogLoaded = false
    /// Tools that aren't installed. The panel shows them with how to install them.
    var missing: [Requirement] = []
    /// Images to download, loaded the first time the New Emulator screen opens.
    var downloadable: [SystemImage]?
    /// Why the images to download couldn't be loaded. The New Emulator screen offers a retry.
    var imagesError: String?
    private var loadingImages = false
    var activity: [String: Activity] = [:]
    /// scrcpy windows this app opened, by device serial.
    private(set) var mirrors: [String: Process] = [:]
    /// Mirroring state of the sample devices in demo mode.
    private var demoMirrors: Set<String> = []
    /// Name of the emulator being created, and how far its system image download got.
    var creating: String?
    var creatingProgress: InstallProgress?
    var loaded = false
    var error: String?

    private var versions: [String: String] = [:]
    private var tracker: DeviceTracker?
    private var refreshingDevices = false
    private var devicesChangedAgain = false

    var runningCount: Int { avds.filter(\.isRunning).count }
    var hasScrcpy: Bool { Tools.scrcpy != nil }

    private init() {
        Task { await poll() }
    }

    /// Keeps the lists and the menu bar icon current. Real devices update right away through
    /// `adb track-devices`. Polling also runs while an emulator boots or an image downloads.
    private func poll() async {
        if Demo.isOn {
            startDemo()
            catalog = await DeviceCatalog.load()
            catalogLoaded = true
            return
        }
        await Tools.locateSDK()
        tracker = DeviceTracker { [weak self] in
            Task { await self?.refreshDevices() }
        }
        await refresh()
        catalog = await DeviceCatalog.load()
        catalogLoaded = true
        while true {
            try? await Task.sleep(for: .seconds(5))
            await refresh()
        }
    }

    func refresh() async {
        if Demo.isOn { return }
        async let emulators: Void = refreshEmulators()
        async let connected: Void = refreshDevices()
        _ = await (emulators, connected)
        missing = Requirement.missing(deviceConnected: !devices.isEmpty)
        if catalog.isEmpty && catalogLoaded && AVDManager.executable != nil {
            catalog = await DeviceCatalog.load() // the command-line tools were just installed
        }
        loaded = true
    }

    private func refreshEmulators() async {
        do {
            avds = try await AndroidCLI.list()
        } catch CLIError.notFound {
            avds = [] // the missing tools tile explains it
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Several changes in a row (unauthorized, then device) run one refresh after the other.
    func refreshDevices() async {
        if refreshingDevices {
            devicesChangedAgain = true
            return
        }
        refreshingDevices = true
        defer { refreshingDevices = false }
        repeat {
            devicesChangedAgain = false
            guard var found = try? await ADB.devices() else { continue }
            for i in found.indices where found[i].isReady {
                let serial = found[i].id
                if versions[serial] == nil { versions[serial] = await ADB.androidVersion(serial) }
                found[i].androidVersion = versions[serial]
            }
            devices = found
        } while devicesChangedAgain
    }

    // MARK: Emulators

    private func perform(_ avd: AVD, _ kind: Activity, _ args: [String]) async {
        if Demo.isOn { return await demoPerform(avd, kind) }
        activity[avd.id] = kind
        defer { activity[avd.id] = nil }
        do {
            try await AndroidCLI.run(args)
            error = nil
        } catch {
            self.error = "\(avd.displayName): \(error.localizedDescription)"
        }
        await refresh()
    }

    func start(_ avd: AVD, cold: Bool = false) async {
        await perform(avd, .starting, ["emulator", "start"] + (cold ? ["--cold"] : []) + [avd.id])
    }

    func stop(_ avd: AVD) async {
        await perform(avd, .stopping, ["emulator", "stop", avd.serial ?? avd.id])
    }

    func wipe(_ avd: AVD) async {
        if Demo.isOn { return await demoPerform(avd, .wiping) }
        activity[avd.id] = .wiping
        defer { activity[avd.id] = nil }
        do {
            try AndroidCLI.wipeData(avd.id)
            error = nil
        } catch {
            self.error = "\(avd.displayName): \(error.localizedDescription)"
        }
        await refresh()
    }

    func remove(_ avd: AVD) async {
        await perform(avd, .removing, ["emulator", "remove", avd.id])
    }

    // MARK: Real devices

    func isMirroring(_ device: PhysicalDevice) -> Bool {
        mirrors[device.id] != nil || demoMirrors.contains(device.id)
    }

    /// Opens a scrcpy window for the device. The window stays open on its own,
    /// so the app only remembers the process to show its state and close it.
    func mirror(_ device: PhysicalDevice) {
        if Demo.isOn {
            demoMirrors.insert(device.id)
            return
        }
        guard let scrcpy = Tools.scrcpy else {
            error = "scrcpy isn't installed. Run: brew install scrcpy"
            return
        }
        guard mirrors[device.id] == nil else { return }
        let process = Process()
        process.executableURL = scrcpy
        process.arguments = ["-s", device.id, "--window-title", device.model, "--stay-awake"]
        process.environment = Tools.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let serial = device.id
        let name = device.model
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let output = collector.string
            let status = p.terminationStatus
            Task { @MainActor in
                self.mirrors[serial] = nil
                // scrcpy exits with 0 when its window closes and 2 when the device disconnects.
                if status != 0 && status != 2 {
                    let line = output.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") }
                    self.error = "\(name): \(line.map(String.init) ?? "scrcpy exited with \(status)")"
                }
            }
        }
        do {
            try process.run()
            mirrors[serial] = process
            error = nil
        } catch {
            self.error = "\(name): \(error.localizedDescription)"
        }
    }

    func stopMirroring(_ device: PhysicalDevice) {
        demoMirrors.remove(device.id)
        mirrors[device.id]?.terminate()
    }

    func loadDownloadable() async {
        guard downloadable == nil, !loadingImages, !Demo.isOn else { return }
        loadingImages = true
        defer { loadingImages = false }
        imagesError = nil
        do {
            downloadable = try await SystemImage.downloadable()
        } catch {
            imagesError = error.localizedDescription
        }
    }

    func create(_ device: DeviceDefinition, image: SystemImage, name: String) async {
        creating = name.isEmpty ? AVDManager.defaultName(device, image) : name
        defer {
            creating = nil
            creatingProgress = nil
        }
        if Demo.isOn { return await demoCreate(device, image: image, name: creating ?? name) }
        do {
            if !image.installed {
                let watch = DownloadWatch()
                let poll = Task {
                    while !Task.isCancelled {
                        creatingProgress = watch.progress
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                defer { poll.cancel() }
                try await AVDManager.install(image, watch: watch)
                creatingProgress = nil
            }
            try await AVDManager.create(device, image: image, name: name, existing: Set(avds.map(\.id)))
            error = nil
        } catch {
            self.error = "Couldn't create \(device.name): \(error.localizedDescription)"
        }
        if !image.installed { downloadable?.removeAll { $0 == image } }
        await refresh()
    }

    // MARK: Windows

    /// Brings the emulator's window to the front.
    func show(_ avd: AVD) {
        if let pid = avd.pid { activate(pid) }
    }

    /// Brings the scrcpy window to the front.
    func showMirror(_ device: PhysicalDevice) {
        if let pid = mirrors[device.id]?.processIdentifier { activate(pid) }
    }

    func canShow(_ avd: AVD) -> Bool { avd.pid != nil || (Demo.isOn && avd.isRunning) }

    private func activate(_ pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}
