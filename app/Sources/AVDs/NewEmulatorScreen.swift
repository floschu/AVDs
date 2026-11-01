import SwiftUI

/// Android Studio's "Add device" flow as its own screen: filter the catalog by text and form
/// factors, pick a device, a system image and a name. Works from the keyboard: type to search,
/// arrows pick a device, Return moves on to the name, Return again creates.
struct NewEmulatorScreen: View {
    let model: Model
    let back: () -> Void
    /// Selected form factors, comma separated. Empty shows all of them.
    @AppStorage("newEmulatorFormFactors") private var formFactorsRaw = DeviceCategory.phone.rawValue
    @State private var deviceID: DeviceDefinition.ID?
    @State private var imagePackage: String?
    @State private var name = ""
    @State private var search = ""
    @FocusState private var focus: Field?

    private enum Field { case search, name }

    private var formFactors: Set<DeviceCategory> {
        Set(formFactorsRaw.split(separator: ",").compactMap { DeviceCategory(rawValue: String($0)) })
    }

    private func toggle(_ category: DeviceCategory) {
        var selected = formFactors
        if selected.contains(category) { selected.remove(category) } else { selected.insert(category) }
        formFactorsRaw = DeviceCategory.allCases.filter(selected.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Both filters apply together: the selected form factors (all when none is selected) and the text.
    private var devices: [DeviceDefinition] {
        let selected = formFactors
        return model.catalog.filter { d in
            (selected.isEmpty || selected.contains(d.category))
                && (search.isEmpty || d.name.localizedCaseInsensitiveContains(search)
                    || d.manufacturer.localizedCaseInsensitiveContains(search))
        }
    }

    private var device: DeviceDefinition? {
        devices.first { $0.id == deviceID } ?? devices.first
    }

    /// Images follow the selected device: a watch needs a Wear OS image, a phone a phone image.
    private var imageCategory: DeviceCategory { device?.category ?? .phone }

    private var installedImages: [SystemImage] { SystemImage.installed(for: imageCategory) }

    /// The newest images per tag that aren't installed yet.
    private var downloadImages: [SystemImage] {
        let installed = Set(installedImages.map(\.package))
        return (model.downloadable ?? [])
            .filter { imageCategory.accepts(imageTag: $0.tag) && !installed.contains($0.package) }
            .sorted(by: SystemImage.newestFirst)
            .prefix(12)
            .map { $0 }
    }

    private var image: SystemImage? {
        let all = installedImages + downloadImages
        return all.first { $0.package == imagePackage } ?? installedImages.first ?? downloadImages.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 8) {
                filters
                filterSummary
            }
            deviceList
            VStack(alignment: .leading, spacing: 10) {
                imagePicker
                nameAndCreate
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .onChange(of: imageCategory) {
            imagePackage = nil
        }
        .onExitCommand(perform: back)
        .task {
            // After the slide, so the field doesn't take focus while it moves in.
            try? await Task.sleep(for: .milliseconds(400))
            focus = .search
        }
    }

    /// The plain text fields on glass have no focus ring of their own.
    private func focusRing(_ focused: Bool) -> some View {
        Capsule()
            .strokeBorder(Color.accentColor.opacity(focused ? 0.7 : 0), lineWidth: 1.5)
            .animation(.easeOut(duration: 0.15), value: focused)
            .allowsHitTesting(false)
    }

    private func moveSelection(_ step: Int) {
        guard !devices.isEmpty else { return }
        let index = devices.firstIndex { $0.id == device?.id } ?? 0
        deviceID = devices[min(max(index + step, 0), devices.count - 1)].id
    }

    private func create() {
        guard let device, let image, model.creating == nil else { return }
        let chosen = name
        name = ""
        Task { await model.create(device, image: image, name: chosen) }
        back()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            Text("New Emulator").font(.headline)
            Spacer()
        }
    }

    /// Search and form factor toggles in one row. They combine.
    private var filters: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search devices")
                    .focused($focus, equals: .search)
                    .onSubmit {
                        deviceID = device?.id
                        focus = .name
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(-1)
                        return .handled
                    }
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .glassEffect(.regular, in: .capsule)
            .overlay { focusRing(focus == .search) }
            .padding(.trailing, 2)
            ForEach(DeviceCategory.allCases) { c in
                let on = formFactors.contains(c)
                Button {
                    toggle(c)
                } label: {
                    Image(systemName: c.systemImage)
                        .font(.system(size: 12))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .frame(width: 26, height: 26)
                        .glassEffect(on ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .tooltip(c.rawValue)
                .accessibilityLabel(c.rawValue)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// Says which form factors show, since the toggles are only icons. Several can be on at once.
    private var filterSummary: some View {
        let selected = DeviceCategory.allCases.filter(formFactors.contains)
        let names = selected.isEmpty ? "All form factors" : ListFormatter.localizedString(byJoining: selected.map(\.rawValue))
        return HStack(spacing: 6) {
            Text("\(names) · \(devices.count) \(devices.count == 1 ? "device" : "devices")")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !selected.isEmpty || !search.isEmpty {
                Button("Show All") {
                    formFactorsRaw = ""
                    search = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }

    private var deviceList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.catalog.isEmpty && model.catalogLoaded {
                        Text("The device list comes with the Android SDK command-line tools. Install them with:\nandroid sdk install cmdline-tools/latest")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(10)
                    } else if model.catalog.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading device catalog…")
                        }
                        .foregroundStyle(.secondary)
                        .padding(10)
                    } else if devices.isEmpty {
                        Text("No devices").foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(devices) { d in
                        let selected = d.id == device?.id
                        Button {
                            deviceID = d.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: d.systemImage)
                                    .frame(width: 20)
                                    .foregroundStyle(selected ? Color.white : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(d.name).lineLimit(1)
                                        if d.custom {
                                            Text("Custom").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(d.specs)
                                        .font(.caption)
                                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // The list's corner radius minus its 4 point inset, so the corners run parallel.
                            .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 14))
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .contentShape(.rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            // Keeps the scroll bar clear of the rounded corners.
            .contentMargins(.vertical, 12, for: .scrollIndicators)
            .onChange(of: deviceID) {
                proxy.scrollTo(deviceID)
            }
        }
        .frame(height: 296)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var imagePicker: some View {
        HStack(spacing: 6) {
            Picker("System image", selection: Binding(
                get: { image?.package ?? "" },
                set: { imagePackage = $0 }
            )) {
                if image == nil {
                    Text(model.downloadable == nil && model.imagesError == nil
                         ? "Loading images…" : "No \(imageCategory.rawValue) images").tag("")
                }
                if !installedImages.isEmpty {
                    Section("Installed") {
                        ForEach(installedImages, id: \.package) { i in
                            Text(i.label).tag(i.package)
                        }
                    }
                }
                if !downloadImages.isEmpty {
                    Section("Download") {
                        ForEach(downloadImages, id: \.package) { i in
                            Label(i.label, systemImage: "arrow.down.circle").tag(i.package)
                        }
                    }
                }
            }
            .controlSize(.small)
            if model.downloadable == nil && model.imagesError == nil {
                ProgressView().controlSize(.mini)
            }
        }
        .task { await model.loadDownloadable() }
        if let error = model.imagesError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't load the images to download.")
                    .tooltip(error)
                Spacer(minLength: 4)
                Button("Retry") {
                    Task { await model.loadDownloadable() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
        } else if let image, !image.installed {
            Label("Downloads the image first. That can take a few minutes.", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var nameAndCreate: some View {
        HStack(spacing: 8) {
            TextField(device.flatMap { d in image.map { AVDManager.defaultName(d, $0) } } ?? "Name", text: $name)
                .textFieldStyle(.plain)
                .accessibilityLabel("Name")
                .focused($focus, equals: .name)
                .onSubmit(create)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .glassEffect(.regular, in: .capsule)
                .overlay { focusRing(focus == .name) }
            Button(action: create) {
                Text(image?.installed == false ? "Download and Create" : "Create")
            }
            .buttonStyle(.glassProminent)
            .disabled(device == nil || image == nil || model.creating != nil)
        }
    }
}
