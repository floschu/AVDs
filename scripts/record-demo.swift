// Records the demo. scripts/record-demo.sh compiles and runs this. Don't run it by hand.
//
// Usage:
//   record-demo measure
//     Prints "EMULATOR <width> <height>", the size of the running emulator's windows in points.
//   record-demo <pid of AVDs> <main .mov> <bar .mov> <AVD folder> <AVD display name> <emulator width> <emulator height>
//     Records a fixed area around the menu bar icon: the panel, the emulator window and, if a
//     phone is connected, its scrcpy window, over the wallpaper. Nothing else, not even the menu
//     bar. A second recording holds the menu bar from the app's icon to the clock.
//     record-demo.sh lays it over the first, without the items of other apps between the icon
//     and Apple's items. Prints "AREA <x> <y> <width> <height>", "BAR <x> <y>" relative to the
//     area, and "HIDE <from> <to>", the part of the bar to leave out, in points.
//     It ends the way it starts, with the panel closed and no windows, so the video loops.
//
// It finds controls by their accessibility labels, so it doesn't depend on the order of the rows.
import AppKit
import ApplicationServices
import ScreenCaptureKit

@Sendable func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

/// Keeps the run loop going while waiting, so AppKit and the capture keep working.
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Waits until `condition` returns something, up to `timeout` seconds.
func waitFor<T>(_ timeout: Double, _ condition: () -> T?) -> T? {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let value = condition() { return value }
        wait(0.02)
    }
    return nil
}

final class ResultBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var result: Result<T, Error>?
}

/// Runs async work while the main run loop keeps going.
func run<T>(_ work: @escaping @Sendable () async throws -> T) -> T {
    let box = ResultBox<T>()
    Task.detached {
        let result: Result<T, Error>
        do { result = .success(try await work()) } catch { result = .failure(error) }
        box.lock.withLock { box.result = result }
    }
    while true {
        if let result = box.lock.withLock({ box.result }) {
            switch result {
            case .success(let value): return value
            case .failure(let error): fail("capture failed: \(error.localizedDescription)")
            }
        }
        wait(0.02)
    }
}

/// Windows of other processes whose name starts with `owner`, like "qemu-system" or "scrcpy".
func windows(of owner: String) -> [(pid: pid_t, bounds: CGRect)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard (window["kCGWindowOwnerName"] as? String)?.hasPrefix(owner) == true,
              let ownerPID = window["kCGWindowOwnerPID"] as? pid_t,
              let bounds = window["kCGWindowBounds"] as? [String: Double],
              bounds["Width"]! > 20, (window["kCGWindowLayer"] as? Int) == 0 else { return nil }
        return (ownerPID, CGRect(x: bounds["X"]!, y: bounds["Y"]!, width: bounds["Width"]!, height: bounds["Height"]!))
    }
}

let args = CommandLine.arguments
if args.count == 2, args[1] == "measure" {
    let all = windows(of: "qemu-system").map(\.bounds)
    guard let first = all.first else { fail("no emulator window") }
    let union = all.dropFirst().reduce(first) { $0.union($1) }
    print("EMULATOR \(Int(union.width)) \(Int(union.height))")
    exit(0)
}
guard args.count == 8, let pid = pid_t(args[1]), let emulatorWidth = Double(args[6]),
      let emulatorHeight = Double(args[7]) else {
    fputs("usage: record-demo measure | record-demo <pid> <main .mov> <icon .mov> <AVD folder> <AVD name> <width> <height>\n", stderr)
    exit(2)
}
let mainOutput = URL(fileURLWithPath: args[2])
let barOutput = URL(fileURLWithPath: args[3])
let avdFolder = URL(fileURLWithPath: args[4])
let avdName = args[5]
let emulatorSize = CGSize(width: emulatorWidth, height: emulatorHeight)

/// The recorded area in points, 16:10. Wide enough for scrcpy, the emulator and the panel.
let area = CGSize(width: 1600, height: 1000)
let gap = 40.0

// MARK: Accessibility

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let position: AXValue = attribute(element, kAXPositionAttribute),
          let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position, .cgPoint, &origin)
    AXValueGetValue(size, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}

/// The first element below `root` that matches, depth first.
func find(_ root: AXUIElement, depth: Int = 0, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
    if matches(root) { return root }
    guard depth < 30, let children: [AXUIElement] = attribute(root, kAXChildrenAttribute) else { return nil }
    for child in children {
        if let found = find(child, depth: depth + 1, matches) { return found }
    }
    return nil
}

let appElement = AXUIElementCreateApplication(pid)

/// A control in the panel by its accessibility label, like "Launch Pixel 10".
func control(_ label: (String) -> Bool) -> AXUIElement? {
    guard let windows: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) else { return nil }
    for window in windows {
        if let found = find(window, { element in
            guard let description: String = attribute(element, kAXDescriptionAttribute) else { return false }
            return label(description)
        }) { return found }
    }
    return nil
}

func control(_ label: String) -> AXUIElement? { control { $0 == label } }

/// The app's menu bar item. CGWindowList doesn't list it.
func statusItemFrame() -> CGRect {
    guard let bar: AXUIElement = attribute(appElement, "AXExtrasMenuBar"),
          let item = (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?)?.first,
          let box = frame(item)
    else { fail("can't find the menu bar item. Does the terminal have Accessibility access?") }
    return box
}

/// The panel's frame in screen points, top left origin. Nil while it's closed.
func panelFrame() -> CGRect? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where (window["kCGWindowOwnerPID"] as? pid_t) == pid {
        guard let bounds = window["kCGWindowBounds"] as? [String: Double],
              let width = bounds["Width"], width >= 300 else { continue }
        return CGRect(x: bounds["X"]!, y: bounds["Y"]!, width: width, height: bounds["Height"]!)
    }
    return nil
}

// MARK: Input

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

/// Glides the pointer, so the video shows where it goes.
func move(to target: CGPoint, duration: Double = 0.45) {
    let start = CGEvent(source: nil)?.location ?? target
    let steps = max(Int(duration * 60), 1)
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        post(.mouseMoved, CGPoint(x: start.x + (target.x - start.x) * eased,
                                  y: start.y + (target.y - start.y) * eased))
        wait(duration / Double(steps))
    }
}

func click(_ point: CGPoint) {
    move(to: point)
    wait(0.2)
    post(.leftMouseDown, point)
    wait(0.06)
    post(.leftMouseUp, point)
}

/// Clicks a control in the open panel. Stops if the panel closed, so no click lands elsewhere.
func click(_ element: AXUIElement) {
    guard panelFrame() != nil, let box = frame(element) else {
        fail("the panel closed unexpectedly, stopping before a click lands elsewhere")
    }
    click(CGPoint(x: box.midX, y: box.midY))
}

/// Presses one key, like 125 for Down or 53 for Escape.
func press(_ key: CGKeyCode) {
    for down in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
    }
    wait(0.12)
}

func type(_ text: String) {
    for character in text {
        var units = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event?.post(tap: .cghidEventTap)
        }
        wait(0.14)
    }
}

func openPanel() {
    guard panelFrame() == nil else { return }
    let item = statusItemFrame()
    click(CGPoint(x: item.midX, y: item.midY))
    guard waitFor(3, { panelFrame() }) != nil else { fail("the panel didn't open") }
    wait(0.5)
}

func closePanel() {
    guard panelFrame() != nil else { return }
    let item = statusItemFrame()
    click(CGPoint(x: item.midX, y: item.midY))
    _ = waitFor(3, { panelFrame() == nil ? true : nil })
}

// MARK: Capture

final class Finished: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isDone: Bool { lock.withLock { done } }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { lock.withLock { done = true } }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        fputs("note: a recording output stopped: \(error.localizedDescription)\n", stderr)
        lock.withLock { done = true }
    }
}

/// The main display and the apps whose windows the main recording shows: AVDs, the wallpaper,
/// and the processes in `pids`, like the emulator and scrcpy once they run.
/// The filter only covers windows that exist when it's made. Off-screen windows count too, so it
/// includes the closed panel, which the layout step opened once.
@Sendable func mainFilter(pids: Set<pid_t>) async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
        fail("can't find the main display. Does the terminal have Screen Recording access?")
    }
    let apps = content.applications.filter {
        pids.contains($0.processID) || $0.bundleIdentifier == "com.apple.WindowManager" // draws the wallpaper
    }
    return SCContentFilter(display: display, including: apps, exceptingWindows: [])
}

/// Everything on the main display, for the menu bar.
@Sendable func fullFilter() async throws -> SCContentFilter {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
        fail("can't find the main display")
    }
    return SCContentFilter(display: display, excludingWindows: [])
}

@Sendable func record(_ rect: CGRect, filter: SCContentFilter, to url: URL, delegate: Finished,
                      streamDelegate: SCStreamDelegate) async throws -> SCStream {
    try? FileManager.default.removeItem(at: url)
    let config = SCStreamConfiguration()
    let scale = Double(filter.pointPixelScale)
    config.sourceRect = rect
    config.width = Int(rect.width * scale)
    config.height = Int(rect.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.showsCursor = true
    config.queueDepth = 8
    let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
    let recordingConfig = SCRecordingOutputConfiguration()
    recordingConfig.outputURL = url
    recordingConfig.outputFileType = .mov
    recordingConfig.videoCodecType = .h264
    try stream.addRecordingOutput(SCRecordingOutput(configuration: recordingConfig, delegate: delegate))
    try await stream.startCapture()
    return stream
}

// MARK: Layout

NSApplication.shared.setActivationPolicy(.accessory)

openPanel()
let panel = panelFrame()!
guard control("Launch \(avdName)") != nil else { fail("can't find the Launch button of \(avdName)") }
let hasPhone = control { $0.hasPrefix("Mirror ") } != nil
closePanel()

// The area hangs from the top of the screen, with the panel near its right edge. Near the right
// edge of the screen it goes all the way, so the clock shows in full.
let screen = CGDisplayBounds(CGMainDisplayID())
let areaRight = screen.maxX - panel.maxX < 400 ? screen.maxX : panel.maxX + 60
let areaX = max(screen.minX, areaRight - area.width)
let rect = CGRect(x: areaX, y: screen.minY, width: area.width, height: area.height)
let item = statusItemFrame()

/// Apple's menu bar items right of the app's icon. Items of other apps between the two get
/// left out of the video.
func appleItems() -> [CGRect] {
    var frames: [CGRect] = []
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.hasPrefix("com.apple.") == true {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar: AXUIElement = attribute(element, "AXExtrasMenuBar"),
              let items: [AXUIElement] = attribute(bar, kAXChildrenAttribute) else { continue }
        frames += items.compactMap { frame($0) }.filter { $0.minX > item.maxX - 6 } // neighbours overlap a little
    }
    return frames
}
let apple = appleItems()
let appleStart = apple.map(\.minX).min() ?? item.maxX
// The menu bar from the app's icon to the clock, in even pixels for H.264. It stops there, so the
// screen recording indicator right of the clock stays out.
let barX = ((item.minX - 4) / 2).rounded(.down) * 2
let barEnd = min(rect.maxX, (apple.map(\.maxX).max() ?? item.maxX) + 4)
let barRect = CGRect(x: barX, y: screen.minY, width: ((barEnd - barX) / 2).rounded(.down) * 2,
                     height: ((item.maxY - screen.minY + 2) / 2).rounded(.up) * 2)
let hide = appleStart - item.maxX > 8 ? (from: item.maxX + 2 - barX, to: appleStart - 2 - barX) : (from: 0.0, to: 0.0)

// The emulator window opens left of the panel. It reads its position from emulator-user.ini
// and writes it back when it exits, so set it right before the launch. record-demo.sh set the scale.
let emulatorOrigin = CGPoint(x: panel.minX - gap - emulatorSize.width, y: panel.minY + 12)
let userIni = avdFolder.appendingPathComponent("emulator-user.ini")
let ini = ((try? String(contentsOf: userIni, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    .filter { !$0.hasPrefix("window.x") && !$0.hasPrefix("window.y") }
    + ["window.x = \(Int(emulatorOrigin.x))", "window.y = \(Int(emulatorOrigin.y))"]
try (ini.joined(separator: "\n") + "\n").write(to: userIni, atomically: true, encoding: .utf8)

/// Moves and sizes the scrcpy window left of the emulator, as tall as the emulator.
func placeMirror(pid mirrorPID: pid_t) {
    let app = AXUIElementCreateApplication(mirrorPID)
    guard let window = (attribute(app, kAXWindowsAttribute) as [AXUIElement]?)?.first,
          let current = frame(window) else { return }
    let height = emulatorSize.height
    var size = CGSize(width: (height * current.width / current.height).rounded(), height: height.rounded())
    var origin = CGPoint(x: emulatorOrigin.x - gap - size.width, y: emulatorOrigin.y)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
}

// MARK: Run

let restingSpot = CGPoint(x: rect.midX - 160, y: rect.midY + 120)
move(to: restingSpot, duration: 0.6)
var shown: Set<pid_t> = [pid]

/// The two streams, main area and menu bar, recorded into numbered files like demo-main.0.mov.
/// macOS sometimes stops both at once with "Unknown stream error", for example when the app's
/// menu bar icon changes right next to Apple's items as the emulator quits. Then a new pair
/// starts right away, and record-demo.sh joins the files.
final class Recording: NSObject, SCStreamDelegate, @unchecked Sendable {
    private(set) var segment = -1
    private(set) var main: SCStream?
    private(set) var bar: SCStream?
    private(set) var mainDone = Finished()
    private(set) var barDone = Finished()

    func file(_ url: URL, _ n: Int) -> URL {
        url.deletingPathExtension().appendingPathExtension("\(n).mov")
    }

    func start() {
        segment += 1
        let n = segment
        mainDone = Finished()
        barDone = Finished()
        let (mainDone, barDone) = (self.mainDone, self.barDone)
        bar = run { try await record(barRect, filter: try await fullFilter(), to: self.file(barOutput, n),
                                     delegate: barDone, streamDelegate: self) }
        main = run { [shown] in
            try await record(rect, filter: try await mainFilter(pids: shown), to: self.file(mainOutput, n),
                             delegate: mainDone, streamDelegate: self)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        DispatchQueue.main.async {
            // Both streams of a pair report it. Restart once.
            guard stream === self.main || stream === self.bar else { return }
            fputs("note: the recording stopped (\(error.localizedDescription)), starting a new part\n", stderr)
            let other = stream === self.main ? self.bar : self.main
            self.main = nil
            self.bar = nil
            if let other { Task { try? await other.stopCapture() } }
            self.start()
        }
    }

    func stop() {
        guard let main, let bar else { return }
        self.main = nil
        self.bar = nil
        run { try? await main.stopCapture() }
        run { try? await bar.stopCapture() }
        let (mainDone, barDone) = (self.mainDone, self.barDone)
        guard waitFor(10, { mainDone.isDone && barDone.isDone ? true : nil }) != nil else { fail("the recording didn't finish") }
    }
}
let recording = Recording()
recording.start()

/// Adds a process's windows to the main recording.
func show(_ newPID: pid_t) {
    shown.insert(newPID)
    guard let main = recording.main else { return }
    run { [shown] in try await main.updateContentFilter(try await mainFilter(pids: shown)) }
}

wait(0.8)
openPanel()
wait(0.6)
click(control("Launch \(avdName)")!)
// Quick boot takes a few seconds. The panel closes when the emulator window comes up.
guard let emulatorPID = waitFor(30, { windows(of: "qemu-system").first?.pid }) else {
    fail("the emulator window didn't appear")
}
show(emulatorPID)
move(to: restingSpot, duration: 0.8)
_ = waitFor(30) { control("Stop \(avdName)") }
wait(2.5)

var mirrorPID: pid_t?
if hasPhone {
    openPanel()
    wait(0.5)
    if let mirror = control({ $0.hasPrefix("Mirror ") }) {
        click(mirror)
        // Placed before it shows up in the recording, so it doesn't jump.
        mirrorPID = waitFor(15) { windows(of: "scrcpy").first?.pid }
        if let mirrorPID {
            placeMirror(pid: mirrorPID)
            wait(0.1)
            show(mirrorPID)
        }
        wait(2.5)
    }
}

// The New Emulator screen, filtered to foldables.
openPanel()
wait(0.5)
guard let newEmulator = control("New emulator") else { fail("can't find the New emulator button") }
click(newEmulator)
wait(1.4)
type("fold")
wait(1.2)
press(125) // Down picks the next device
wait(0.8)
press(125)
wait(1.6)

// Back to how it started, so the video loops: stop everything and close the panel.
press(53) // Escape goes back to the list
wait(0.8)
if let mirrorPID, let stopMirror = control({ $0.hasPrefix("Stop mirroring ") }) {
    click(stopMirror)
    _ = waitFor(10) { windows(of: "scrcpy").contains { $0.pid == mirrorPID } ? nil : true }
    wait(0.6)
}
openPanel()
guard let stop = control("Stop \(avdName)") else { fail("can't find the Stop button of \(avdName)") }
click(stop)
_ = waitFor(30) { windows(of: "qemu-system").isEmpty ? true : nil }
wait(0.6)
closePanel()
move(to: restingSpot, duration: 0.8)
wait(0.8)

recording.stop()
print("PARTS \(recording.segment + 1)")
if let mirrorPID { kill(mirrorPID, SIGTERM) }
print("AREA \(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
print("BAR \(Int(barRect.minX - rect.minX)) \(Int(barRect.minY - rect.minY))")
print("HIDE \(Int(hide.from)) \(Int(hide.to))")
