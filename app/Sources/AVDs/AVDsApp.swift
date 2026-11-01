import SwiftUI
import ServiceManagement
import AppKit

@main
struct AVDsApp: App {
    @State private var model = Model.shared
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // AVDS_PREVIEW=1 shows the panel in a normal window, for screenshots while developing.
        if ProcessInfo.processInfo.environment["AVDS_PREVIEW"] == "1" {
            let model = _model.wrappedValue
            DispatchQueue.main.async {
                let window = NSWindow(contentViewController: NSHostingController(rootView: MenuView(model: model)
                    .defaultAppStorage(Demo.isOn ? Demo.defaults : .standard)))
                window.title = "AVDs Preview"
                window.styleMask = [.titled, .closable, .fullSizeContentView]
                window.titlebarAppearsTransparent = true
                window.center()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
                .defaultAppStorage(Demo.isOn ? Demo.defaults : .standard)
        } label: {
            Image(nsImage: BarIcon.image(running: model.runningCount > 0))
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Android head as a template image. While an emulator runs, a dot sits in the top right corner.
enum BarIcon {
    private static let variants = [make(badge: false), make(badge: true)]

    static func image(running: Bool) -> NSImage { variants[running ? 1 : 0] }

    private static func make(badge: Bool) -> NSImage {
        let logo = Bundle.main.image(forResource: "MenuIcon")
        let logoSize = logo?.size ?? NSSize(width: 23, height: 14)
        let canvas = NSSize(width: logoSize.width + 5, height: 18)
        let image = NSImage(size: canvas, flipped: false) { _ in
            let rect = NSRect(x: 1, y: (canvas.height - logoSize.height) / 2 - 1,
                              width: logoSize.width, height: logoSize.height)
            if let logo {
                logo.draw(in: rect)
            } else {
                NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)?.draw(in: rect)
            }
            if badge {
                let dot = NSRect(x: canvas.width - 6, y: canvas.height - 6, width: 5, height: 5)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "AVDs, emulator running" : "AVDs"
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var rightClickMonitor: Any?

    /// Registers the login item on the first launch from /Applications only. After that the toggle
    /// in the panel decides. A build run from elsewhere never registers.
    func applicationDidFinishLaunching(_ notification: Notification) {
        installRightClickMenu()
        let defaults = UserDefaults.standard
        if Bundle.main.bundlePath.hasPrefix("/Applications/"), !defaults.bool(forKey: "loginItemSetUp") {
            defaults.set(true, forKey: "loginItemSetUp")
            try? SMAppService.mainApp.register()
        }
    }

    /// MenuBarExtra has no right-click menu, so this catches right clicks on the status item
    /// and shows the app menu instead of opening the panel.
    private func installRightClickMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            guard let window = event.window,
                  window.className.contains("StatusBar"),
                  let view = window.contentView else { return event }
            let menu = self.contextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        }
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? "AVDs"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let title = NSMenuItem(title: "\(name) \(version) (\(build))", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        menu.addItem(item("Refresh", #selector(refresh), key: "r"))
        let login = item("Open at Login", #selector(toggleLoginItem))
        let status = SMAppService.mainApp.status
        login.state = status == .enabled || status == .requiresApproval ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(item("Report an Issue…", #selector(openIssues)))
        let developer = item("Developed by FLOSCH", #selector(openWebsite))
        developer.attributedTitle = Self.developedBy()
        menu.addItem(developer)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    /// "Developed by [logo] FLOSCH", with the logo inline at the size of the capital letters.
    private static func developedBy() -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: "Developed by  ", attributes: [.font: font])
        if let logo = Bundle.main.image(forResource: "FloschLogo") {
            let side = font.capHeight + 1
            let gap: CGFloat = 5 // extra space between "by" and the logo, on top of the normal space
            let size = NSSize(width: gap + side, height: side)
            let tinted = NSImage(size: size, flipped: false) { _ in
                let rect = NSRect(x: gap, y: 0, width: side, height: side)
                logo.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = NSRect(x: 0, y: -0.5, width: size.width, height: size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        text.append(NSAttributedString(string: "FLOSCH", attributes: [.font: font]))
        return text
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refresh() {
        Task { await Model.shared.refresh() }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        let on = service.status == .enabled || service.status == .requiresApproval
        do {
            if on { try service.unregister() } else { try service.register() }
        } catch {
            Model.shared.error = "Couldn't \(on ? "disable" : "enable") open at login: \(error.localizedDescription)"
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://flosch.at/")!)
    }

    @objc private func openIssues() {
        NSWorkspace.shared.open(URL(string: "https://github.com/floschu/AVDs/issues")!)
    }
}
