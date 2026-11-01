import Foundation

enum DeviceKind {
    case phone, foldable, tablet, wear, tv, desktop, automotive, xr

    var systemImage: String {
        switch self {
        case .phone: "smartphone"
        case .foldable: "rectangle.portrait.split.2x1"
        case .tablet: "ipad.landscape"
        case .wear: "applewatch"
        case .tv: "tv"
        case .desktop: "desktopcomputer"
        case .automotive: "car"
        case .xr: "visionpro"
        }
    }

    init(tag: String, device: String, name: String) {
        let all = "\(tag) \(device) \(name)".lowercased()
        if all.contains("wear") { self = .wear }
        else if all.contains("tv") || all.contains("television") { self = .tv }
        else if all.contains("automotive") || all.contains("car") { self = .automotive }
        else if all.contains("desktop") { self = .desktop }
        else if all.contains("xr") || all.contains("glasses") { self = .xr }
        else if all.contains("fold") { self = .foldable }
        else if all.contains("tablet") || all.contains("foldable") { self = .tablet }
        else { self = .phone }
    }
}

struct AVD: Identifiable, Hashable {
    let id: String
    let api: String
    let status: String
    let serial: String?
    var displayName: String
    var kind: DeviceKind
    var variant: String?

    /// The emulator process, from the process list. The CLI's status flips between Online and
    /// Offline while an emulator boots, so this decides whether it runs.
    var pid: Int32?
    /// Demo mode has no processes, so its sample emulators set this instead.
    var demoRunning = false

    var hasProcess: Bool { pid != nil || demoRunning }

    var isOnline: Bool { status.lowercased() == "online" && serial != nil }
    var isRunning: Bool { hasProcess || isOnline }

    /// "Wear OS 6.0" -> "Wear OS". The API level next to it already says which version.
    var variantName: String? {
        variant.map { $0.replacingOccurrences(of: #"\s+[0-9.]+$"#, with: "", options: .regularExpression) }
    }

    /// "android-37.0" -> "API 37"
    var apiLabel: String {
        let n = api.replacingOccurrences(of: "android-", with: "")
        return "API " + (n.hasSuffix(".0") ? String(n.dropLast(2)) : n)
    }
}

enum CLIError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "The android CLI isn't in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin."
        case .failed(let output): output.isEmpty ? "The command failed." : Self.lastLine(output)
        }
    }

    /// The CLI prints progress without newlines, so keep the end of the output only.
    private static func lastLine(_ output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return String((lines.last { !$0.isEmpty } ?? output).suffix(300))
    }
}

enum AndroidCLI {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    @discardableResult
    static func run(_ args: [String], timeout: Duration? = nil,
                    onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let android = Tools.android else { throw CLIError.notFound }
        return try await Shell.run(android, args, timeout: timeout, onOutput: onOutput)
    }

    static func list() async throws -> [AVD] {
        let output = try await run(["emulator", "list", "--long"], timeout: .seconds(20))
        let running = await runningAVDs()
        let lines = output.split(separator: "\n").map(String.init)
        guard let header = lines.first(where: { $0.hasPrefix("AVD ID") }) else { return [] }
        // Names can contain spaces, so cut each line at the header's column positions.
        let starts = ["AVD ID", "AVD Name", "API Level", "Status", "Serial"].map { title in
            header.range(of: title).map { header.distance(from: header.startIndex, to: $0.lowerBound) }
        }
        func column(_ line: String, _ i: Int) -> String {
            guard let start = starts[i], start < line.count else { return "" }
            let end = starts[(i + 1)...].compactMap { $0 }.first ?? line.count
            let from = line.index(line.startIndex, offsetBy: start)
            let to = line.index(line.startIndex, offsetBy: min(end, line.count))
            return line[from..<to].trimmingCharacters(in: .whitespaces)
        }
        return lines
            .drop { $0 != header }
            .dropFirst()
            .compactMap { line in
                let id = column(line, 0)
                guard !id.isEmpty else { return nil }
                let serial = column(line, 4)
                let config = readConfig(id)
                let tag = config["tag.id"] ?? ""
                let device = config["hw.device.name"] ?? ""
                let name = column(line, 1)
                var avd = AVD(
                    id: id,
                    api: column(line, 2),
                    status: column(line, 3),
                    serial: serial.isEmpty ? nil : serial,
                    displayName: config["avd.ini.displayname"] ?? (name.isEmpty ? id : name).replacingOccurrences(of: "_", with: " "),
                    kind: DeviceKind(tag: tag, device: device, name: id),
                    variant: config["tag.displaynames"]?.split(separator: ",").first.map(String.init)
                )
                avd.pid = running[id]
                return avd
            }
    }

    /// Process IDs of running emulators by AVD name, from `qemu-system-* @name` or `-avd name`.
    private static func runningAVDs() async -> [String: Int32] {
        guard let output = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid,command"],
                                                timeout: .seconds(5)) else { return [:] }
        var running: [String: Int32] = [:]
        for line in output.split(separator: "\n") where line.contains("qemu-system") {
            let args = line.split(separator: " ").map(String.init)
            guard let pid = args.first.flatMap({ Int32($0) }) else { continue }
            if let at = args.first(where: { $0.hasPrefix("@") }) {
                running[String(at.dropFirst())] = pid
            } else if let i = args.firstIndex(of: "-avd"), i + 1 < args.count {
                running[args[i + 1]] = pid
            }
        }
        return running
    }

    /// Deletes the user data, cache and snapshots, like Wipe Data in Android Studio.
    /// The next boot starts from a fresh copy of the system image's user data.
    static func wipeData(_ id: String) throws {
        let dir = directory(id)
        let fm = FileManager.default
        let names = ["userdata-qemu.img", "userdata-qemu.img.qcow2", "cache.img", "cache.img.qcow2",
                     "encryptionkey.img", "encryptionkey.img.qcow2", "snapshots", "multiinstance.lock"]
        for name in names where fm.fileExists(atPath: "\(dir)/\(name)") {
            try fm.removeItem(atPath: "\(dir)/\(name)")
        }
    }

    /// Reads `<id>.avd/config.ini` for the device type and display name. Missing keys are fine.
    private static func readConfig(_ id: String) -> [String: String] {
        guard let config = try? String(contentsOfFile: "\(directory(id))/config.ini", encoding: .utf8) else { return [:] }
        return parse(config)
    }

    /// The `.avd` folder, from the `path` in `<id>.ini`.
    static func directory(_ id: String) -> String {
        let avdHome = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"] ?? "\(home)/.android/avd"
        if let ini = try? String(contentsOfFile: "\(avdHome)/\(id).ini", encoding: .utf8),
           let path = parse(ini)["path"] {
            return path
        }
        return "\(avdHome)/\(id).avd"
    }

    private static func parse(_ ini: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in ini.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}

enum Shell {
    /// Runs a command to the end and returns its combined output. `onOutput` sees each chunk as it
    /// arrives, for progress. Throws on a non-zero exit, and
    /// after `timeout` (then the process gets terminated), so one stuck call can't stall the app.
    @discardableResult
    static func run(_ executable: URL, _ args: [String],
                    environment: [String: String] = Tools.environment, input: String? = nil,
                    timeout: Duration? = nil,
                    onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin

            let run = RunState()
            let name = executable.lastPathComponent
            @Sendable func finish() {
                guard let result = run.finish() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                switch result {
                case .exited(let status, let output):
                    if status == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(throwing: CLIError.failed(output))
                    }
                case .timedOut:
                    continuation.resume(throwing: CLIError.failed("\(name) \(args.first ?? "") didn't answer in time."))
                }
            }

            // Read while it runs so a full pipe never blocks the process. Empty data means EOF.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    run.reachedEOF()
                    finish()
                } else {
                    run.append(data)
                    onOutput?(String(decoding: data, as: UTF8.self))
                }
            }
            process.terminationHandler = { p in
                run.exited(p.terminationStatus)
                finish()
                // A background process it started (like the adb server) can keep the pipe open.
                // Don't wait for EOF longer than a moment then.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    run.reachedEOF()
                    finish()
                }
            }
            if let timeout {
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    guard run.timeOut() else { return }
                    process.terminate()
                    finish()
                }
            }
            do {
                try process.run()
                if let input {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                    try? stdin.fileHandleForWriting.close()
                }
            } catch {
                if run.finish(force: true) != nil { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Tracks a running command: its output, exit and EOF. Hands out the result exactly once.
private final class RunState: @unchecked Sendable {
    enum Result {
        case exited(Int32, String)
        case timedOut
    }

    private let lock = NSLock()
    private var data = Data()
    private var status: Int32?
    private var eof = false
    private var timedOut = false
    private var done = false

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func reachedEOF() { lock.withLock { eof = true } }
    func exited(_ code: Int32) { lock.withLock { status = code } }

    /// Marks the run as timed out unless it already finished.
    func timeOut() -> Bool {
        lock.withLock {
            guard !done, status == nil else { return false }
            timedOut = true
            return true
        }
    }

    /// The result once the process exited and its output ended, or after a timeout. Nil before
    /// that and on every later call.
    func finish(force: Bool = false) -> Result? {
        lock.withLock {
            guard !done else { return nil }
            if timedOut || force {
                done = true
                return .timedOut
            }
            guard let status, eof else { return nil }
            done = true
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .exited(status, output)
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
