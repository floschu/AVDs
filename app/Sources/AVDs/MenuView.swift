import SwiftUI
import AppKit

/// Dropdown content of the menu bar item. Built from system controls and Liquid Glass.
/// Two screens: the device list, and New Emulator, which slides in from the right like on iOS.
struct MenuView: View {
    let model: Model
    @State private var pending: PendingAction?
    @State private var creatingScreen = false
    @State private var listHeight: CGFloat = 0
    @State private var newScreenHeight: CGFloat = 485
    /// Set only while switching screens, so the window height animates from one screen to the
    /// other. Nil the rest of the time, so the list can grow and shrink with its rows.
    @State private var panelHeight: CGFloat?
    /// Option is down: Launch turns into Cold Boot, like menu items in Finder.
    @State private var optionHeld = false
    @State private var modifierMonitor: Any?
    /// The list has more rows above or below what fits. The edge fades out then.
    @State private var moreAbove = false
    @State private var moreBelow = false
    @State private var copiedError = false

    var body: some View {
        ZStack(alignment: .top) {
            if creatingScreen {
                NewEmulatorScreen(model: model, back: showList)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { newScreenHeight = $0 }
                    .transition(.move(edge: .trailing))
            } else {
                listScreen
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                    .transition(.move(edge: .leading))
            }
        }
        .frame(height: panelHeight, alignment: .top)
        .padding(12)
        .frame(width: 380)
        .clipped()
        .onAppear {
            // An accessory app's panel opens without activating the app, so the first click
            // would only activate the window.
            NSApp.activate()
            Task { await model.refresh() }
            optionHeld = NSEvent.modifierFlags.contains(.option)
            if modifierMonitor == nil {
                modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    optionHeld = event.modifierFlags.contains(.option)
                    return event
                }
            }
        }
    }

    private var listScreen: some View {
        VStack(spacing: 10) {
            header
            if let error = model.error {
                errorTile(error)
            }
            ScrollView {
                // The glass container sits inside the scroll view: it draws the glass of its
                // rows, so the fading mask below only reaches the glass from out here.
                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        if !model.missing.isEmpty {
                            MissingToolsTile(missing: model.missing)
                        }
                        deviceRows
                    }
                }
                // Room for the glass edges, which the scroll view would cut off otherwise.
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            // With a mouse connected, macOS reserves room for a scroll bar on the right, and the
            // rows would end short of the header. No bar, the edges fade out instead.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                [geometry.visibleRect.minY > 1,
                 geometry.visibleRect.maxY < geometry.contentSize.height - 1]
            } action: { _, edges in
                withAnimation(.easeOut(duration: 0.2)) {
                    moreAbove = edges[0]
                    moreBelow = edges[1]
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: moreAbove ? 24 : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: moreBelow ? 32 : 0)
                }
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, -4)
            .padding(.vertical, -2)
        }
        .animation(.snappy, value: model.avds)
        .animation(.snappy, value: model.devices)
    }

    private static let slide = Animation.smooth(duration: 0.35)

    private func showNewEmulator() {
        panelHeight = listHeight
        withAnimation(Self.slide) {
            panelHeight = newScreenHeight
            creatingScreen = true
        } completion: {
            panelHeight = nil
        }
    }

    private func showList() {
        panelHeight = newScreenHeight
        withAnimation(Self.slide) {
            panelHeight = listHeight
            creatingScreen = false
        } completion: {
            panelHeight = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: BarIcon.image(running: false))
                .renderingMode(.template)
            Text("AVDs").font(.headline)
            Spacer()
            Button(action: showNewEmulator) {
                Image(systemName: "plus")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tooltip("New emulator")
            .accessibilityLabel("New emulator")
        }
        .padding(.leading, 4)
    }

    private func errorTile(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
                copiedError = true
            } label: {
                Image(systemName: copiedError ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tooltip("Copy the message")
            .accessibilityLabel("Copy")
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .tooltip("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .onChange(of: message) { copiedError = false }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 18))
    }

    // MARK: List

    /// Real devices first, then emulators, in one list. A device has a cable or Wi-Fi badge.
    @ViewBuilder
    private var deviceRows: some View {
        if let creating = model.creating {
            let progress = model.creatingProgress
            DeviceRow(systemImage: "plus", title: creating, subtitle: progress?.label ?? "Creating…",
                      active: false, status: nil) {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction).progressViewStyle(.circular).controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        ForEach(model.devices) { device in
            deviceRow(device)
        }
        ForEach(model.avds) { avd in
            emulatorRow(avd)
        }
        if model.loaded && model.avds.isEmpty && model.devices.isEmpty && model.creating == nil
            && !model.missing.contains(where: { $0.id == "android" }) {
            VStack(spacing: 4) {
                Text("No emulators or devices")
                Text("Create an emulator with + or plug in a device.")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else if !model.loaded {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(14)
        }
    }

    /// One row per emulator. A pending Wipe Data or Remove asks right in the row: same tile, same
    /// height, only the text and buttons change, so the panel doesn't resize or morph its glass.
    private func emulatorRow(_ avd: AVD) -> some View {
        let activity = model.activity[avd.id]
        let confirm = pending?.avd == avd.id ? pending?.kind : nil
        let subtitle = [avd.apiLabel, avd.variantName].compactMap { $0 }.joined(separator: " · ")
        let showable = confirm == nil && avd.isRunning && model.canShow(avd)
        return DeviceRow(
            systemImage: confirm?.systemImage ?? avd.kind.systemImage,
            title: confirm.map { $0.question(avd.displayName) } ?? avd.displayName,
            subtitle: confirm?.detail ?? subtitle,
            active: avd.isRunning,
            status: confirm != nil ? nil
                : activity.map(Self.label)
                    ?? (avd.isOnline ? avd.serial.map { "\(avd.apiLabel) · \($0)" } : avd.isRunning ? "Booting…" : nil),
            warning: confirm != nil,
            open: showable ? { model.show(avd) } : nil,
            openHint: avd.headless ? "Mirror the emulator with scrcpy, it runs without a window" : "Show the emulator window"
        ) {
            if let confirm {
                Button("Cancel") {
                    setPending(nil)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
                Button(confirm.action, role: .destructive) {
                    setPending(nil)
                    Task { confirm == .remove ? await model.remove(avd) : await model.wipe(avd) }
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .fixedSize()
            } else {
                runButton(avd, activity)
                moreMenu(avd, activity)
            }
        }
        .rowMenu {
            confirm == nil ? emulatorMenuItems(avd, activity, withMainAction: true) : []
        }
    }

    @ViewBuilder
    private func runButton(_ avd: AVD, _ activity: Activity?) -> some View {
        if avd.isRunning {
            Button {
                Task { await model.stop(avd) }
            } label: {
                RowButtonLabel(title: "Stop", systemImage: "stop.fill", busy: activity == .stopping)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .disabled(activity != nil)
            .tooltip("Shut down the emulator")
            .accessibilityLabel("Stop \(avd.displayName)")
        } else {
            let cold = optionHeld && activity == nil
            Button {
                Task { await model.start(avd, cold: NSEvent.modifierFlags.contains(.option)) }
            } label: {
                RowButtonLabel(title: cold ? "Cold Boot" : "Launch", systemImage: cold ? "snowflake" : "play.fill",
                               busy: activity == .starting)
            }
            .buttonStyle(.glassProminent)
            .disabled(activity != nil)
            .tooltip("Boot from the last snapshot. Hold Option to cold boot.")
            .accessibilityLabel("\(cold ? "Cold boot" : "Launch") \(avd.displayName)")
        }
    }

    private func moreMenu(_ avd: AVD, _ activity: Activity?) -> some View {
        Menu {
            RowMenuContent(items: emulatorMenuItems(avd, activity))
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        // The glass menu button doesn't show up for VoiceOver, a plain menu does.
        .accessibilityRepresentation {
            Menu("More actions for \(avd.displayName)") {
                RowMenuContent(items: emulatorMenuItems(avd, activity))
            }
        }
    }

    /// The "…" menu. The right-click menu adds Launch or Stop on top.
    private func emulatorMenuItems(_ avd: AVD, _ activity: Activity?, withMainAction: Bool = false) -> [RowMenuItem] {
        var items: [RowMenuItem] = []
        if withMainAction {
            items.append(avd.isRunning
                ? .action("Stop", systemImage: "stop.fill", enabled: activity == nil) {
                    Task { await model.stop(avd) }
                }
                : .action("Launch", systemImage: "play.fill", enabled: activity == nil) {
                    Task { await model.start(avd) }
                })
        }
        if avd.isRunning {
            items.append(.action("Show Window", systemImage: "macwindow", enabled: model.canShow(avd)) {
                model.show(avd)
            })
            if avd.headless && !model.canShow(avd) {
                items.append(.note(model.hasScrcpy
                    ? "Runs without a window. It can be mirrored once it has booted."
                    : "Runs without a window. Install scrcpy to mirror it."))
            }
        }
        if let serial = avd.serial, avd.isRunning {
            items.append(.copySerial(serial))
        }
        if !items.isEmpty { items.append(.divider) }
        let idle = !avd.isRunning && activity == nil
        items += [
            .action("Cold Boot", systemImage: "snowflake", enabled: idle) {
                Task { await model.start(avd, cold: true) }
            },
            .action("Wipe Data…", systemImage: "eraser", enabled: idle) {
                setPending(PendingAction(avd: avd.id, kind: .wipe))
            },
            .divider,
            .action("Remove…", systemImage: "trash", enabled: idle, destructive: true) {
                setPending(PendingAction(avd: avd.id, kind: .remove))
            },
        ]
        if avd.isRunning {
            items += [.divider, .note("Stop the emulator to cold boot, wipe or remove it.")]
        }
        return items
    }

    private static func label(_ activity: Activity) -> String {
        switch activity {
        case .starting: "Booting…"
        case .stopping: "Shutting down…"
        case .removing: "Removing…"
        case .wiping: "Wiping data…"
        }
    }

    private func setPending(_ action: PendingAction?) {
        withAnimation(.easeInOut(duration: 0.15)) { pending = action }
    }

    // MARK: Real devices

    private func deviceRow(_ device: PhysicalDevice) -> some View {
        let mirroring = model.isMirroring(device)
        return DeviceRow(
            systemImage: "smartphone",
            badge: device.usb ? "cable.connector" : "wifi",
            title: device.model,
            subtitle: [device.androidVersion, device.stateLabel].compactMap { $0 }.joined(separator: " · "),
            active: mirroring,
            status: mirroring ? "Mirroring" : nil,
            open: mirroring ? { model.showMirror(device) } : nil,
            openHint: "Show the scrcpy window"
        ) {
            if mirroring {
                Button {
                    model.stopMirroring(device)
                } label: {
                    RowButtonLabel(title: "Stop", systemImage: "stop.fill", busy: false)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .tooltip("Stop mirroring and close the scrcpy window")
                .accessibilityLabel("Stop mirroring \(device.model)")
            } else {
                Button {
                    model.mirror(device)
                } label: {
                    RowButtonLabel(title: "Mirror", systemImage: "rectangle.on.rectangle", busy: false)
                }
                .buttonStyle(.glassProminent)
                .disabled(!device.isReady || !model.hasScrcpy)
                .tooltip(model.hasScrcpy
                    ? "Mirror the screen with scrcpy. You can control the device from the window."
                    : "Needs scrcpy. See Missing tools above.")
                .accessibilityLabel("Mirror \(device.model)")
            }
            menuPlaceholder
        }
        .rowMenu {
            (mirroring
                ? [.action("Stop Mirroring", systemImage: "stop.fill") { model.stopMirroring(device) },
                   .action("Show Window", systemImage: "macwindow") { model.showMirror(device) }]
                : [.action("Mirror", systemImage: "rectangle.on.rectangle",
                           enabled: device.isReady && model.hasScrcpy) { model.mirror(device) }])
                + [.divider, .copySerial(device.id)]
        }
    }

    /// Takes the room of an emulator row's "…" menu, so the main buttons of all rows line up.
    private var menuPlaceholder: some View {
        Menu {} label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
    }
}

// MARK: - Building blocks

/// Lists tools that aren't installed, what each one is for and how to install it.
private struct MissingToolsTile: View {
    let missing: [Requirement]
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Missing tools", systemImage: "wrench.and.screwdriver")
                .font(.headline)
            ForEach(missing) { requirement in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(requirement.title).font(.callout.weight(.semibold))
                        Text(requirement.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    switch requirement.fix {
                    case .command(let command):
                        HStack(spacing: 6) {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                                copied = command
                            } label: {
                                Image(systemName: copied == command ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .tooltip("Copy the command, then run it in Terminal")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
                    case .link(let title, let url):
                        Link(title, destination: url)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.2)), in: .rect(cornerRadius: 18))
    }
}

private struct PendingAction: Equatable {
    enum Kind {
        case wipe, remove

        var systemImage: String { self == .remove ? "trash" : "eraser" }
        var action: String { self == .remove ? "Remove" : "Wipe" }
        var detail: String {
            self == .remove ? "Deletes the emulator" : "Deletes apps and data"
        }

        func question(_ name: String) -> String {
            self == .remove ? "Remove \(name)?" : "Wipe \(name)?"
        }
    }

    let avd: AVD.ID
    let kind: Kind
}

/// One glass tile per emulator or device: icon, name, details and the row's buttons.
private struct DeviceRow<Actions: View>: View {
    let systemImage: String
    /// Marks a real device: a small symbol on the icon's corner.
    var badge: String? = nil
    let title: String
    let subtitle: String
    let active: Bool
    let status: String?
    var warning = false
    /// Clicking the icon or the text calls this, like Show Window. Nil when there's nothing to show.
    var open: (() -> Void)? = nil
    var openHint = ""
    @ViewBuilder let actions: Actions

    private var iconColor: Color {
        warning ? .red : active ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                details
                Spacer(minLength: 8)
            }
            .contentShape(.rect)
            .onTapGesture { open?() }
            .tooltip(open == nil ? "" : openHint)
            .accessibilityActions {
                if let open { Button("Show Window", action: open) }
            }
            HStack(spacing: 6) { actions }
                .controlSize(.regular)
        }
        .padding(10)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var details: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(iconColor)
            .frame(width: 38, height: 38)
            .glassEffect(warning ? .regular.tint(.red.opacity(0.3))
                         : active ? .regular.tint(.green.opacity(0.3)) : .regular, in: .circle)
            .contentTransition(.symbolEffect(.replace))
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 16, height: 16)
                        .glassEffect(.regular, in: .circle)
                        .offset(x: 3, y: 3)
                }
            }
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(warning ? .tail : .middle)
                .contentTransition(.opacity)
            Text(status ?? subtitle)
                .font(.caption)
                .foregroundStyle(status != nil && active ? Color.green : Color.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
    }
}

private struct RowButtonLabel: View {
    let title: String
    let systemImage: String
    let busy: Bool

    /// Every main button is as wide as the widest label, so they line up across rows and
    /// Launch keeps its width when Option turns it into Cold Boot.
    var body: some View {
        ZStack {
            content(title: "Cold Boot", systemImage: "snowflake", busy: false).hidden()
            content(title: "Mirror", systemImage: "rectangle.on.rectangle", busy: false).hidden()
            content(title: title, systemImage: systemImage, busy: busy)
        }
    }

    private func content(title: String, systemImage: String, busy: Bool) -> some View {
        HStack(spacing: 5) {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: systemImage).font(.caption)
            }
            Text(title)
        }
    }
}
