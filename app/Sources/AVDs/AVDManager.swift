import Foundation

/// A system image, such as `system-images;android-37.0;google_apis_playstore_ps16k;arm64-v8a`.
/// Either installed or available to download.
struct SystemImage: Hashable {
    let platform: String // android-37.0, android-35-ext15, android-37.2-beta1
    let tag: String // google_apis_playstore_ps16k
    let abi: String
    var installed = true

    var package: String { "system-images;\(platform);\(tag);\(abi)" }
    var path: String { "system-images/\(platform)/\(tag)/\(abi)" }
    var hasPlayStore: Bool { tag.contains("playstore") }

    private var version: String {
        String(platform.dropFirst("android-".count).prefix { $0.isNumber || $0 == "." })
    }

    var apiLevel: Double { Double(version) ?? 0 }

    var apiLabel: String {
        var label = "API " + (version.hasSuffix(".0") ? String(version.dropLast(2)) : version)
        let suffix = platform.dropFirst("android-".count + version.count)
        if suffix.hasPrefix("-ext") { label += " ext \(suffix.dropFirst(4))" }
        if suffix.hasPrefix("-beta") { label += " Beta \(suffix.dropFirst(5))" }
        return label
    }

    /// `API 37 · Google Play · 16 KB pages`
    var label: String {
        var parts = [apiLabel]
        if tag.contains("wear") { parts.append("Wear OS") }
        else if tag.contains("google-tv") { parts.append("Google TV") }
        else if tag.contains("tv") { parts.append("Android TV") }
        else if tag.contains("automotive") { parts.append(hasPlayStore ? "Automotive, Google Play" : "Automotive") }
        else if tag.contains("desktop") { parts.append("Desktop") }
        else if tag.contains("glasses") { parts.append("AI Glasses") }
        else if tag.contains("xr") { parts.append(hasPlayStore ? "XR, Google Play" : "XR") }
        else if hasPlayStore { parts.append("Google Play") }
        else if tag.contains("google_apis") { parts.append("Google APIs") }
        if tag.contains("tablet") { parts.append("Tablet") }
        if tag.contains("preview") { parts.append("Preview") }
        if tag.contains("ps16k") { parts.append("16 KB pages") }
        if abi != "arm64-v8a" { parts.append(abi) }
        return parts.joined(separator: " · ")
    }

    /// Test images (ATD) have no UI apps, so they don't belong in a device picker.
    var isUsable: Bool { !tag.contains("atd") }

    init(platform: String, tag: String, abi: String, installed: Bool = true) {
        self.platform = platform
        self.tag = tag
        self.abi = abi
        self.installed = installed
    }

    /// From `system-images/android-36/google-tv/arm64-v8a`.
    init?(path: String, installed: Bool) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "system-images" else { return nil }
        self.init(platform: parts[1], tag: parts[2], abi: parts[3], installed: installed)
    }

    static func newestFirst(_ a: SystemImage, _ b: SystemImage) -> Bool {
        func rank(_ i: SystemImage) -> Int { i.hasPlayStore ? 2 : i.tag.contains("google_apis") ? 1 : 0 }
        func beta(_ i: SystemImage) -> Int { i.platform.contains("beta") ? 0 : 1 }
        return (a.apiLevel, beta(a), rank(a), a.platform) > (b.apiLevel, beta(b), rank(b), b.platform)
    }

    /// Images in the SDK repository that aren't installed, for this Mac's CPU.
    static func downloadable() async throws -> [SystemImage] {
        let output = try await AndroidCLI.run(["sdk", "list", "--all"], timeout: .seconds(90))
        #if arch(arm64)
        let abi = "arm64-v8a"
        #else
        let abi = "x86_64"
        #endif
        return output
            .split(separator: "\n")
            .drop { !$0.contains("Available packages") }
            .compactMap { line in
                line.split(whereSeparator: \.isWhitespace).first.flatMap { SystemImage(path: String($0), installed: false) }
            }
            .filter { $0.abi == abi && $0.isUsable }
    }

    /// Installed images that fit the category, newest first. Google Play images come before
    /// Google APIs and plain ones of the same API level.
    static func installed(for category: DeviceCategory) -> [SystemImage] {
        let root = "\(Tools.sdk)/system-images"
        let fm = FileManager.default
        var images: [SystemImage] = []
        for platform in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for tag in (try? fm.contentsOfDirectory(atPath: "\(root)/\(platform)")) ?? []
            where category.accepts(imageTag: tag) {
                for abi in (try? fm.contentsOfDirectory(atPath: "\(root)/\(platform)/\(tag)")) ?? []
                where fm.fileExists(atPath: "\(root)/\(platform)/\(tag)/\(abi)/system.img") {
                    images.append(SystemImage(platform: platform, tag: tag, abi: abi))
                }
            }
        }
        return images.filter(\.isUsable).sorted(by: newestFirst)
    }
}

enum AVDManager {
    static var executable: URL? {
        let path = "\(Tools.sdk)/cmdline-tools/latest/bin/avdmanager"
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// avdmanager needs Java: Android Studio's bundled runtime, JAVA_HOME, or an installed JDK.
    static var javaHome: String? {
        let fm = FileManager.default
        var candidates = ["/Applications/Android Studio.app/Contents/jbr/Contents/Home"]
        if let env = ProcessInfo.processInfo.environment["JAVA_HOME"] { candidates.append(env) }
        for root in ["/Library/Java/JavaVirtualMachines",
                     "\(fm.homeDirectoryForCurrentUser.path)/Library/Java/JavaVirtualMachines"] {
            let jdks = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            candidates += jdks.sorted(by: >).map { "\(root)/\($0)/Contents/Home" }
        }
        return candidates.first { fm.isExecutableFile(atPath: "\($0)/bin/java") }
    }

    /// Creates an AVD the way Android Studio's Device Manager does: the device definition (with
    /// hinge sensors for foldables), the chosen image, the device frame, Play Store, keyboard and GPU on.
    /// The image has to be installed, see `install`.
    @discardableResult
    static func create(_ profile: DeviceDefinition, image: SystemImage, name requested: String,
                       existing: Set<String>) async throws -> String {
        guard let executable else {
            throw CLIError.failed("avdmanager is missing. Install the Android SDK Command-line Tools.")
        }
        let trimmed = requested.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? defaultName(profile, image) : trimmed
        var name = base
        var n = 2
        while existing.contains(id(for: name)) {
            name = "\(base) (\(n))"
            n += 1
        }
        let avdID = id(for: name)

        var args = ["create", "avd", "-n", avdID, "-k", image.package, "-d", profile.id]
        if let skin = profile.skin { args += ["--skin", skin] }
        var env = Tools.environment
        if let javaHome { env["JAVA_HOME"] = javaHome }
        // avdmanager asks whether to create a custom hardware profile. "no" keeps the device's own.
        try await Shell.run(executable, args, environment: env, input: "no\n")

        try patchConfig(avdID, [
            "avd.ini.displayname": name,
            "PlayStore.enabled": image.hasPlayStore ? "yes" : "no",
            "hw.keyboard": "yes",
            "hw.gpu.enabled": "yes",
        ])
        return name
    }

    /// Downloads and unpacks a system image. `watch` follows the download for the progress.
    static func install(_ image: SystemImage, watch: DownloadWatch) async throws {
        try await AndroidCLI.run(["sdk", "install", image.path]) { watch.output($0) }
    }

    static func defaultName(_ profile: DeviceDefinition, _ image: SystemImage) -> String {
        "\(profile.name) \(image.apiLabel)"
    }

    private static func id(for name: String) -> String {
        name.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func patchConfig(_ avdID: String, _ values: [String: String]) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let avdHome = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"] ?? "\(home)/.android/avd"
        let url = URL(fileURLWithPath: "\(avdHome)/\(avdID).avd/config.ini")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        var remaining = values
        for i in lines.indices {
            let key = lines[i].split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if let value = remaining.removeValue(forKey: key) { lines[i] = "\(key)=\(value)" }
        }
        if lines.last == "" { lines.removeLast() }
        lines += remaining.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

enum InstallProgress: Equatable {
    case downloading(received: Int64, total: Int64?)
    case unpacking

    var fraction: Double? {
        guard case .downloading(let received, let total?) = self, total > 0 else { return nil }
        return min(Double(received) / Double(total), 1)
    }

    /// "Downloading · 420 MB of 1.1 GB"
    var label: String {
        switch self {
        case .downloading(let received, let total):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            guard received > 0 else { return "Downloading…" }
            return "Downloading · " + format(received) + (total.map { " of " + format($0) } ?? "")
        case .unpacking:
            return "Installing the image…"
        }
    }
}

/// Follows `android sdk install`, which prints no percentage. The CLI prints the archive's URL
/// first, so the size comes from the server. It downloads into `<sdk>/.sdk/arch/<hash>.part`,
/// so the received bytes come from that file. "Unzipping" in the output ends the download.
final class DownloadWatch: @unchecked Sendable {
    private let folder = "\(Tools.sdk)/.sdk/arch"
    private let started = Date().addingTimeInterval(-2)
    private let lock = NSLock()
    private var total: Int64?
    private var askedForSize = false
    private var unpacking = false

    func output(_ chunk: String) {
        if chunk.contains("Unzipping") { lock.withLock { unpacking = true } }
        guard let match = chunk.firstMatch(of: #/https://\S+?\.zip/#),
              let url = URL(string: String(match.output)) else { return }
        let first = lock.withLock {
            defer { askedForSize = true }
            return !askedForSize
        }
        guard first else { return }
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            // expectedContentLength is -1 for a HEAD request, the header has the size.
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"),
                  let size = Int64(length), size > 0 else { return }
            lock.withLock { total = size }
        }
    }

    var progress: InstallProgress {
        let (total, unpacking) = lock.withLock { (self.total, self.unpacking) }
        if unpacking { return .unpacking }
        let fm = FileManager.default
        let received = ((try? fm.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasSuffix(".part") }
            .compactMap { try? fm.attributesOfItem(atPath: "\(folder)/\($0)") }
            .filter { ($0[.modificationDate] as? Date ?? .distantPast) > started }
            .compactMap { ($0[.size] as? NSNumber)?.int64Value }
            .max() ?? 0
        return .downloading(received: received, total: total)
    }
}
