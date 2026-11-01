import SwiftUI
import AppKit

/// One entry of a row's menu. The "…" menu and the right-click menu come from the same list.
enum RowMenuItem {
    case action(String, systemImage: String, enabled: Bool = true, destructive: Bool = false,
                perform: () -> Void)
    case divider
    /// A disabled line that explains why other items are disabled.
    case note(String)
}

/// The items as SwiftUI menu content, for a `Menu`.
struct RowMenuContent: View {
    let items: [RowMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .action(let title, let systemImage, let enabled, let destructive, let perform):
                Button(title, systemImage: systemImage, role: destructive ? .destructive : nil, action: perform)
                    .disabled(!enabled)
            case .divider:
                Divider()
            case .note(let text):
                Text(text)
            }
        }
    }
}

extension View {
    /// A right-click and Control-click menu. SwiftUI's `.contextMenu` doesn't open in a menu bar
    /// panel, so this is an AppKit view over the row that only takes those clicks.
    func rowMenu(_ items: @escaping () -> [RowMenuItem]) -> some View {
        overlay(RightClickArea(items: items))
    }
}

private struct RightClickArea: NSViewRepresentable {
    let items: () -> [RowMenuItem]

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.items = items
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        view.items = items
    }

    final class AreaView: NSView {
        var items: () -> [RowMenuItem] = { [] }
        /// True while the right-click monitor looks for the row under the pointer.
        private static var findingRow = false

        /// SwiftUI's context menu doesn't open in the menu bar panel. This monitor finds the row
        /// under a right click and opens its menu instead of passing the click to the panel.
        private static let rightClickMonitor: Any? = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .rightMouseUp]
        ) { event in
            let handled = MainActor.assumeIsolated {
                guard let content = event.window?.contentView else { return false }
                let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                findingRow = true
                let row = content.hitTest(point) as? AreaView
                findingRow = false
                guard let row else { return false }
                if event.type == .rightMouseDown { row.showMenu(event) }
                return true
            }
            return handled ? nil : event
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            _ = Self.rightClickMonitor
        }

        /// Takes only Control-clicks, and the right-click monitor's lookup. Everything else goes
        /// to the row below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let controlClick = NSApp.currentEvent.map {
                [.leftMouseDown, .leftMouseUp].contains($0.type) && $0.modifierFlags.contains(.control)
            } ?? false
            guard Self.findingRow || controlClick else { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) { showMenu(event) }

        fileprivate func showMenu(_ event: NSEvent) {
            let menu = NSMenu()
            for item in items() {
                switch item {
                case .action(let title, let systemImage, let enabled, _, let perform):
                    let menuItem = ClosureMenuItem(title: title, perform: perform)
                    menuItem.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
                    menuItem.isEnabled = enabled
                    menu.addItem(menuItem)
                case .divider:
                    menu.addItem(.separator())
                case .note(let text):
                    let note = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    menu.addItem(note)
                }
            }
            menu.autoenablesItems = false
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { perform() }
}
