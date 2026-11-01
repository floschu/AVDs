import SwiftUI
import AppKit

extension View {
    /// `.help` tooltips don't show in a menu bar panel, because the app never becomes frontmost.
    /// This one behaves like them: it shows after hovering for a moment, a click or key press
    /// cancels it, and it only comes back after the pointer leaves and enters again. It is its own
    /// window that ignores the mouse, so it never catches a click meant for the view below it.
    func tooltip(_ text: String) -> some View {
        accessibilityHint(text)
            .background(TooltipAnchor(text: text))
    }
}

/// An invisible view that tracks the mouse over its area. Tracking areas fire even when other
/// views, like the button itself, sit on top of it.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.text = text
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.text = text
    }

    final class AnchorView: NSView {
        var text = ""
        private var timer: Timer?
        /// Set by a click while hovering. Cleared when the pointer leaves.
        private var suppressed = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            timer?.invalidate()
            TooltipPanel.shared.hovered = self
            guard !text.isEmpty, !suppressed else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.show() }
            }
        }

        override func mouseExited(with event: NSEvent) {
            timer?.invalidate()
            suppressed = false
            if TooltipPanel.shared.hovered === self { TooltipPanel.shared.hovered = nil }
            TooltipPanel.shared.hide()
        }

        /// A click or key press while hovering: no tooltip until the pointer leaves.
        func cancelUntilExit() {
            timer?.invalidate()
            suppressed = true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                timer?.invalidate()
                if TooltipPanel.shared.hovered === self { TooltipPanel.shared.hovered = nil }
                TooltipPanel.shared.hide()
            }
        }

        private func show() {
            guard let window, window.isVisible, !suppressed,
                  !TooltipPanel.shared.pointerRestsAfterClick() else { return }
            // A view can slide under a resting pointer, which fires mouseEntered without a hover.
            let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard bounds.contains(pointer) else { return }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            TooltipPanel.shared.show(text, below: rect)
        }
    }
}

/// One shared borderless window for all tooltips. It ignores mouse events. Any click or key
/// press hides it and cancels the hovered view's pending tooltip.
@MainActor
private final class TooltipPanel {
    static let shared = TooltipPanel()

    weak var hovered: TooltipAnchor.AnchorView?
    /// Where the last click or key press happened, in screen coordinates.
    var lastClick: NSPoint?
    private let panel: NSPanel
    private let host = NSHostingView(rootView: TooltipLabel(text: ""))

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = host
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                TooltipPanel.shared.hovered?.cancelUntilExit()
                TooltipPanel.shared.lastClick = NSEvent.mouseLocation
                TooltipPanel.shared.hide()
            }
            return event
        }
    }

    func show(_ text: String, below anchor: NSRect) {
        host.rootView = TooltipLabel(text: text)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        if origin.y < screen.minY { origin.y = anchor.maxY + 6 }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
    }

    /// True while the pointer hasn't moved since the last click. A click can swap the view under
    /// the pointer, like Launch turning into Stop. The new view gets no tooltip until the pointer
    /// moves, like in AppKit.
    func pointerRestsAfterClick() -> Bool {
        guard let lastClick else { return false }
        let now = NSEvent.mouseLocation
        return abs(now.x - lastClick.x) < 3 && abs(now.y - lastClick.y) < 3
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct TooltipLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .padding(1)
    }
}
