// Records the README demo. scripts/record-demo.sh compiles and runs this. Don't run it by hand.
//
// Usage: record-demo <pid of AVDs in demo mode> <frames folder>
// Captures only the panel window, with a transparent background, as numbered PNGs at `fps`.
// Prints "FPS <n>" and "CROP <width> <height>" (in points) when done.
//
// It clicks at positions relative to the panel. When the panel layout changes, update `Spot`.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3, let pid = pid_t(args[1]) else {
    fputs("usage: record-demo <pid> <frames folder>\n", stderr)
    exit(2)
}
let framesFolder = URL(fileURLWithPath: args[2])
let fps = 15.0

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

/// Keeps the run loop going while waiting, so AppKit and the capture task keep working.
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// Positions inside the panel, from its top left corner, in points.
enum Spot {
    static let plus = CGPoint(x: 355, y: 22)
    static let back = CGPoint(x: 25, y: 22)
    static let search = CGPoint(x: 70, y: 59)
    static func formFactor(_ index: Int) -> CGPoint { CGPoint(x: 174 + Double(index) * 30, y: 59) }
    /// The button on the right of a list row. Rows start at y 72 and are 68 points apart.
    static func rowButton(_ row: Int) -> CGPoint { CGPoint(x: 300, y: 72 + Double(row) * 68) }
}

// MARK: Finding things on screen

/// The menu bar item of the app, through the accessibility API. CGWindowList doesn't list it.
func statusItemCenter() -> CGPoint {
    let app = AXUIElementCreateApplication(pid)
    var extras: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &extras) == .success,
          let bar = extras else { fail("can't find the menu bar item. Does the terminal have Accessibility access?") }
    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
    guard let item = (children as? [AXUIElement])?.first else { fail("the app has no menu bar item") }
    var position: CFTypeRef?
    var size: CFTypeRef?
    AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position)
    AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size)
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
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

func panel() -> CGRect {
    guard let frame = panelFrame() else { fail("the panel closed unexpectedly, stopping before a click lands elsewhere") }
    return frame
}

func inPanel(_ spot: CGPoint) -> CGPoint {
    let frame = panel()
    return CGPoint(x: frame.minX + spot.x, y: frame.minY + spot.y)
}

// MARK: Input

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

/// Glides the pointer, so the GIF shows where it goes.
func move(to target: CGPoint, duration: Double = 0.35) {
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
    wait(0.15)
    post(.leftMouseDown, point)
    wait(0.05)
    post(.leftMouseUp, point)
}

func clickInPanel(_ spot: CGPoint) { click(inPanel(spot)) }

/// Presses one key, like 125 for Down or 36 for Return.
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
        wait(0.12)
    }
}

func togglePanel() {
    let wasOpen = panelFrame() != nil
    click(statusItemCenter())
    for _ in 0..<40 where (panelFrame() != nil) == wasOpen { wait(0.05) }
    wait(0.5)
}

// MARK: Capture

/// Captures the panel window into numbered PNGs until stopped. Only the window: everything
/// around it stays transparent. The canvas is as tall as the tallest screen, top aligned.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private(set) var frames = 0

    func stop() { lock.withLock { running = false } }
    private var isRunning: Bool { lock.withLock { running } }

    func start(pid: pid_t, size: CGSize, folder: URL, fps: Double) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.frame.width >= 300
        }) else { fail("can't find the panel window to capture. Does the terminal have Screen Recording access?") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        config.scalesToFit = false
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        let start = Date()
        while isRunning {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let url = folder.appendingPathComponent(String(format: "frame%05d.png", frames))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            frames += 1
            // Fixed frame times, so the animation plays at real speed.
            let next = start.addingTimeInterval(Double(frames) / fps)
            let delay = next.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
    }
}

// MARK: Run

NSApplication.shared.setActivationPolicy(.accessory)
try? FileManager.default.removeItem(at: framesFolder)
try FileManager.default.createDirectory(at: framesFolder, withIntermediateDirectories: true)

// Measure both screens first, so the canvas fits the taller one. The list gets one more row
// during the recording.
if panelFrame() == nil { togglePanel() }
let listHeight = panel().height + 68
clickInPanel(Spot.plus)
wait(1)
// The capture scales the window down whenever it's bigger than the canvas, and the window grows
// past its final size for a moment while the screens switch. So the canvas gets plenty of room.
// record-demo.sh crops the frames to the size printed as CROP.
let crop = CGSize(width: panel().width, height: max(panel().height, listHeight) + 12)
let canvas = CGSize(width: crop.width + 200, height: crop.height + 300)
clickInPanel(Spot.back)
wait(1)

// Start with the pointer in the middle of the panel.
move(to: CGPoint(x: panel().midX, y: panel().midY), duration: 0.5)
wait(0.3)

let recorder = Recorder()
let recording = Task.detached {
    do { try await recorder.start(pid: pid, size: canvas, folder: framesFolder, fps: fps) } catch { fail("capture failed: \(error.localizedDescription)") }
}
wait(1.2)
clickInPanel(Spot.rowButton(1))      // Launch Pixel 10, boots for 2 s in demo mode
wait(2.8)
clickInPanel(Spot.rowButton(0))      // Mirror the Pixel 9 Pro
wait(1.2)
clickInPanel(Spot.plus)              // New Emulator
wait(1.4)
clickInPanel(Spot.formFactor(1))     // add Tablet to the default Phone
wait(1.1)
clickInPanel(Spot.search)
type("fold")
wait(1.2)
press(125)                           // Down picks the next foldable
wait(0.8)
press(36)                            // Return moves to the name
wait(0.6)
press(36)                            // Return creates it, 1 s in demo mode
wait(2.4)
clickInPanel(Spot.rowButton(0))      // stop mirroring
wait(0.6)
clickInPanel(Spot.rowButton(1))      // stop Pixel 10, 1 s in demo mode
wait(1.6)
move(to: CGPoint(x: panel().midX, y: panel().midY), duration: 0.5)
wait(0.6)

recorder.stop()
wait(0.3) // let the last capture finish writing
togglePanel() // close
print(String(format: "FPS %.0f", fps))
print("CROP \(Int(crop.width)) \(Int(crop.height))")
