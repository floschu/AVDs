import Foundation

/// The device categories of Android Studio's Device Manager.
enum DeviceCategory: String, CaseIterable, Identifiable {
    case phone = "Phone"
    case tablet = "Tablet"
    case wear = "Wear OS"
    case tv = "TV"
    case desktop = "Desktop"
    case automotive = "Automotive"
    case xr = "XR"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .phone: "smartphone"
        case .tablet: "ipad.landscape"
        case .wear: "applewatch"
        case .tv: "tv"
        case .desktop: "desktopcomputer"
        case .automotive: "car"
        case .xr: "visionpro"
        }
    }

    /// Whether a system image tag such as `google_apis_playstore` or `android-wear` fits this category.
    func accepts(imageTag tag: String) -> Bool {
        let special: [(DeviceCategory, [String])] = [
            (.wear, ["wear"]), (.tv, ["-tv", "tv"]), (.automotive, ["automotive"]),
            (.desktop, ["desktop"]), (.xr, ["xr", "glasses"]),
        ]
        let match = special.first { _, needles in needles.contains { tag.contains($0) } }?.0
        switch self {
        case .phone, .tablet: return match == nil
        default: return match == self
        }
    }
}

/// A hardware profile from the SDK's device definitions, the same list Android Studio shows.
struct DeviceDefinition: Identifiable, Hashable {
    let id: String // what avdmanager -d takes
    let name: String
    let manufacturer: String
    let tag: String?
    let diagonal: Double?
    let width: Int?
    let height: Int?
    let density: String?
    let playStore: Bool
    let foldable: Bool
    let custom: Bool

    var category: DeviceCategory {
        switch tag ?? "" {
        case let t where t.contains("wear"): .wear
        case let t where t.contains("tv"): .tv
        case let t where t.contains("automotive"): .automotive
        case let t where t.contains("desktop"): .desktop
        case let t where t.contains("xr") || t.contains("glasses"): .xr
        default: (diagonal ?? 0) >= 7 && !foldable ? .tablet : .phone
        }
    }

    var systemImage: String {
        foldable ? "rectangle.portrait.split.2x1" : category.systemImage
    }

    /// `6.24" · 1080 × 2424 · 420 dpi`
    var specs: String {
        var parts: [String] = []
        if let diagonal { parts.append(String(format: "%g\"", diagonal)) }
        if let width, let height { parts.append("\(width) × \(height)") }
        if let density {
            // "420dpi" -> "420 dpi", buckets like "xxhdpi" stay as they are.
            parts.append(density.first?.isNumber == true ? density.replacingOccurrences(of: "dpi", with: " dpi") : density)
        }
        return parts.joined(separator: " · ")
    }

    /// Device frame from the SDK's skins folder, named like the device id when there is one.
    var skin: String? {
        FileManager.default.fileExists(atPath: "\(Tools.sdk)/skins/\(id)") ? id : nil
    }
}

enum DeviceCatalog {
    private static let files = ["devices", "nexus", "wear", "tv", "automotive", "desktop", "xr"]

    /// Reads the definitions bundled with the command-line tools, plus the user's own hardware
    /// profiles from `~/.android/devices.xml`. Sorted like Studio: newest Pixels first.
    static func load() async -> [DeviceDefinition] {
        let jar = "\(Tools.sdk)/cmdline-tools/latest/lib/sdklib/sdklib.core.jar"
        var devices: [DeviceDefinition] = []
        for file in files {
            if let xml = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                              ["-p", jar, "com/android/sdklib/devices/\(file).xml"]) {
                devices += DeviceXMLParser.parse(Data(xml.utf8), custom: false)
            }
        }
        let userFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/devices.xml")
        if let data = try? Data(contentsOf: userFile) {
            devices += DeviceXMLParser.parse(data, custom: true)
        }
        var seen = Set<String>()
        return devices
            .filter { seen.insert($0.id).inserted }
            .sorted(by: order)
    }

    private static func order(_ a: DeviceDefinition, _ b: DeviceDefinition) -> Bool {
        func group(_ d: DeviceDefinition) -> Int {
            if d.custom { return 0 }
            if d.name.hasPrefix("Pixel") { return 1 }
            if d.manufacturer == "Google" || d.manufacturer == "Generic" { return 2 }
            return 3
        }
        if group(a) != group(b) { return group(a) < group(b) }
        if group(a) == 1 {
            let (ga, gb) = (generation(a.name), generation(b.name))
            if ga != gb { return ga > gb }
        }
        // Within a generation: "Pixel 9", "Pixel 9 Pro", "Pixel 9 Pro Fold", "Pixel 9 Pro XL", "Pixel 9a".
        return a.name.compare(b.name, options: .numeric) == .orderedAscending
    }

    /// Release order of a Pixel name. Models without a number came out before the Pixel 2,
    /// except the Pixel Fold and Pixel Tablet from 2023.
    private static func generation(_ name: String) -> Double {
        let rest = name.dropFirst("Pixel ".count)
        if let n = Double(rest.prefix { $0.isNumber }) { return n }
        if rest.hasPrefix("Fold") || rest.hasPrefix("Tablet") { return 7.5 }
        if rest.hasPrefix("C") { return 1.5 }
        return 1
    }
}

/// Collects the few fields the app shows from `<d:device>` entries.
private final class DeviceXMLParser: NSObject, XMLParserDelegate {
    private let custom: Bool
    private var devices: [DeviceDefinition] = []
    private var fields: [String: String] = [:]
    private var foldable = false
    private var inDevice = false
    private var text = ""

    private init(custom: Bool) { self.custom = custom }

    static func parse(_ data: Data, custom: Bool) -> [DeviceDefinition] {
        let delegate = DeviceXMLParser(custom: custom)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.devices
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = Self.local(elementName)
        if name == "device" {
            inDevice = true
            fields = [:]
            foldable = false
        }
        if name == "posture-list" || name == "x-folded-dimension" { foldable = true }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = Self.local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the first value: the device's own fields come before the per-state ones.
        if inDevice, !value.isEmpty, fields[name] == nil { fields[name] = value }
        if name == "device", inDevice {
            inDevice = false
            guard let deviceName = fields["name"] else { return }
            devices.append(DeviceDefinition(
                id: fields["id"] ?? deviceName,
                name: deviceName,
                manufacturer: fields["manufacturer"] ?? "",
                tag: fields["tag-id"],
                diagonal: fields["diagonal-length"].flatMap(Double.init),
                width: fields["x-dimension"].flatMap { Int($0) },
                height: fields["y-dimension"].flatMap { Int($0) },
                density: fields["pixel-density"],
                playStore: fields["playstore-enabled"] == "true",
                foldable: foldable,
                custom: custom
            ))
        }
        text = ""
    }
}
