import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: messages between the agent and the panel

/// The panel is its own process (see MachSaverPanel), so it and the menu bar
/// agent talk through distributed notifications: the agent broadcasts what
/// it's doing, the panel asks for that on open and sends commands back.
enum Bus {
    static let status = Notification.Name("dev.mach-saver.status")
    static let request = Notification.Name("dev.mach-saver.status.request")
    static let command = Notification.Name("dev.mach-saver.command")

    static func post(_ name: Notification.Name, _ info: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }

    static func observe(_ name: Notification.Name, _ handler: @escaping ([AnyHashable: Any]) -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { handler($0.userInfo ?? [:]) }
    }
}

// MARK: model

final class PanelModel: ObservableObject {
    enum Page: String, CaseIterable {
        case screensavers = "Screensavers", colors = "Colors", settings = "Settings"
        var symbol: String {
            switch self { case .screensavers: "sparkles.tv"; case .colors: "paintpalette.fill"; case .settings: "gearshape.fill" }
        }
    }
    @Published var page: Page = .screensavers

    // From the agent.
    @Published var awake = false
    @Published var heard = false

    // Settings, read and written straight through to the shared defaults.
    @Published var keepAwake = Prefs.keepAwake
    @Published var idleMinutes = Prefs.idleMinutes
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled

    /// Saved screensavers and colourways; every change is written straight back.
    @Published var library = Library.load() { didSet { library.save() } }
    @Published var saverID: String
    @Published var colorID: String

    init() {
        let lib = Library.load()
        saverID = lib.active
        colorID = lib.activeSaver.palette
        // `--page colors` opens on a given page (handy for scripts and screenshots).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--page"), i + 1 < args.count,
           let p = Page.allCases.first(where: { $0.rawValue.lowercased() == args[i + 1].lowercased() }) { page = p }
        Bus.observe(Bus.status) { [weak self] info in
            self?.awake = info["awake"] as? Bool ?? false
            self?.heard = true
        }
        Bus.post(Bus.request)
    }

    var headline: String {
        guard heard else { return "Connecting…" }
        return awake ? "Keeping your Mac awake" : "Your Mac sleeps as usual"
    }

    // MARK: screensavers

    var saver: Library.Saver { library.savers.first { $0.id == saverID } ?? library.activeSaver }

    func edit(_ change: (inout Library.Saver) -> Void) {
        guard let i = library.savers.firstIndex(where: { $0.id == saverID }) else { return }
        change(&library.savers[i])
    }

    func use(_ id: String) { library.active = id }

    func addSaver() {
        var s = saver
        s.id = UUID().uuidString
        s.name = "Screensaver \(library.savers.count + 1)"
        library.savers.append(s)
        saverID = s.id
    }

    func deleteSaver() {
        guard !saver.isDefault else { return }
        let id = saverID
        library.savers.removeAll { $0.id == id }
        if library.active == id { library.active = Library.defaultID }
        saverID = library.active
    }

    func chooseLogo() {
        let panel = NSOpenPanel()
        panel.message = "A braille/ASCII .txt (like fastfetch logos) or an image"
        panel.allowedContentTypes = [.plainText, .text, .image]
        panel.directoryURL = URL(fileURLWithPath: ("~/.config/fastfetch/txt" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { edit { $0.logoPath = url.path } }
    }

    // MARK: colours

    var palettes: [Palette] { Palette.builtIn + library.colorways.map(\.palette) }
    func palette(_ name: String) -> Palette { palettes.first { $0.name == name } ?? Palette.purple }
    var colorway: Library.Colorway? { library.colorways.first { $0.id == colorID } }

    func editColor(_ change: (inout Library.Colorway) -> Void) {
        guard let i = library.colorways.firstIndex(where: { $0.id == colorID }) else { return }
        change(&library.colorways[i])
    }

    /// A new colourway starting from the selected one's colours.
    func addColorway() {
        let c = Library.Colorway(copying: palette(colorID), name: "Custom \(library.colorways.count + 1)")
        library.colorways.append(c)
        colorID = c.id
    }

    func deleteColorway() {
        guard colorway != nil else { return }
        let id = colorID
        library.colorways.removeAll { $0.id == id }
        for i in library.savers.indices where library.savers[i].palette == id { library.savers[i].palette = Palette.purple.name }
        colorID = saver.palette
    }

    func applyColor() { edit { $0.palette = colorID } }

    /// Changes whenever anything the preview draws changes.
    func previewKey(_ s: Library.Saver, _ p: String) -> String {
        let c = library.colorways.first { $0.id == p }.map { "\($0.background)\($0.jetTop)\($0.jetBottom)\($0.textStart)\($0.textEnd)\($0.camo)" } ?? ""
        return "\(s.text)|\(s.logoPath ?? "")|\(p)|\(c)"
    }

    // MARK: settings

    func setKeepAwake(_ m: KeepAwake) { keepAwake = m; Prefs.keepAwake = m; changed() }
    func setIdle(_ m: Double) { idleMinutes = m; Prefs.idleMinutes = m; changed() }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { NSSound.beep() }
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func lock() { MachSaverPanel.close(); ScreenLock.lockNow() }

    func quit() { Bus.post(Bus.command, ["do": "quit"]); MachSaverPanel.close() }

    /// Tells the agent to re-read settings now rather than on its next tick.
    private func changed() { Bus.post(Bus.command, ["do": "refresh"]) }
}

// MARK: panel window

/// A floating dark HUD. Esc or clicking elsewhere dismisses it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        // Stay open while our own open panel is up.
        if NSApp.modalWindow == nil && !(NSApp.keyWindow is NSOpenPanel) { close() }
    }
}

/// Like MouseSkins, the panel runs in its own short-lived process
/// (`MachSaver --panel`, started by the menu bar agent) and quits when it
/// closes, so the agent that sits in the menu bar all day never loads
/// SwiftUI. It opens in the middle of the screen with the pointer.
enum MachSaverPanel {
    static let size = NSSize(width: 820, height: 540)
    private static var panel: FloatingPanel?

    static func show() {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.appearance = NSAppearance(named: .darkAqua)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: PanelView().environmentObject(PanelModel()).tint(Accent.color))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        p.contentView = blur
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        panel = p
        let mouse = NSEvent.mouseLocation
        let f = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                          width: size.width, height: size.height), display: true)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    static func close() { panel?.close() }
}

/// Starts and stops the panel process from the menu bar agent.
enum PanelProcess {
    private static var process: Process?

    static var isOpen: Bool { process?.isRunning == true }

    /// Clicking the menu bar icon again closes it.
    static func toggle() {
        if isOpen { process?.terminate(); process = nil } else { open() }
    }

    static func open() {
        guard !isOpen else { return }
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--panel"]
        do { try p.run(); process = p } catch { NSSound.beep() }
    }
}

enum Accent {
    static let color = Color(red: 0.66, green: 0.33, blue: 0.97)     // #A855F7, MACH's violet
}

extension RGB {
    var color: Color { Color(red: r / 255, green: g / 255, blue: b / 255) }
}

/// Two-way binding between a hex string and a SwiftUI colour, for ColorPicker.
private func hexBinding(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Color> {
    Binding(get: { RGB(hex: get()).color }, set: { c in
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return }
        set(RGB(Double(n.redComponent * 255), Double(n.greenComponent * 255), Double(n.blueComponent * 255)).hex)
    })
}

// MARK: shell

struct PanelView: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            Group {
                switch model.page {
                case .screensavers: ScreensaversPage()
                case .colors: ColorsPage()
                case .settings: SettingsPage()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.black.opacity(0.35))
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mach Saver").font(.system(size: 14, weight: .bold))
                    HStack(spacing: 4) {
                        Circle().fill(model.awake ? Color.green : Color.secondary.opacity(0.6)).frame(width: 6, height: 6)
                        Text(model.headline).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.bottom, 16)

            ForEach(PanelModel.Page.allCases, id: \.self) { page in
                let on = model.page == page
                Button { model.page = page } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol).frame(width: 18)
                        Text(page.rawValue)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Accent.color.opacity(0.85) : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                IconButton("lock.fill", "Lock screen") { model.lock() }
                IconButton("power", "Quit Mach Saver", tint: .red) { model.quit() }
            }
        }
        .padding(.horizontal, 14).padding(.top, 22).padding(.bottom, 16)
        .frame(width: 210)
        .background(alignment: .top) {
            RadialGradient(colors: [Accent.color.opacity(0.25), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                .allowsHitTesting(false)
        }
    }
}

struct IconButton: View {
    let symbol: String, help: String
    var tint: Color? = nil
    var filled = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, _ help: String, tint: Color? = nil, filled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.tint = tint; self.filled = filled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint ?? Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A text button: primary is filled violet, the rest are quiet.
private struct PillButton: View {
    let title: String, symbol: String
    var primary = false
    var tint: Color = .primary
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? Color.white : tint)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(primary ? AnyShapeStyle(Accent.color) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct PageHeader: View {
    let title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A titled group of controls on a rounded card.
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).kerning(0.6)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

/// A label on the left, its control on the right.
private struct Field<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            control
        }
    }
}

/// A palette as a little swatch: background with its text and jet gradients on it.
private struct Swatch: View {
    let palette: Palette
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(palette.background.color)
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: (palette.text ?? palette.accent).map(\.color), startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: palette.accent.map(\.color), startPoint: .top, endPoint: .bottom))
                    .frame(width: 10)
            }
            .padding(6)
        }
    }
}

/// A selectable tile in a strip, with an optional "in use" dot.
private struct Tile<Top: View>: View {
    let title: String
    let selected: Bool
    var inUse = false
    @ViewBuilder var top: Top
    var body: some View {
        VStack(spacing: 5) {
            top.frame(height: 36)
            HStack(spacing: 4) {
                if inUse { Circle().fill(.green).frame(width: 6, height: 6) }
                Text(title).font(.system(size: 10, weight: selected ? .bold : .medium)).lineLimit(1)
            }
        }
        .padding(6)
        .frame(width: 104, height: 70)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(selected ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? Accent.color : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

private struct AddTile: View {
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Accent.color)
                .frame(width: 70, height: 70)
                .background(RoundedRectangle(cornerRadius: 11).strokeBorder(Accent.color.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain).help(help)
    }
}

/// The screensaver itself, running live. Rebuilt when `key` changes.
struct LivePreview: NSViewRepresentable {
    let key: String
    let make: (NSRect) -> Afterburner

    final class Holder { var key = "" }
    func makeCoordinator() -> Holder { Holder() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        v.subviews.forEach { $0.removeFromSuperview() }
        let scene = make(v.bounds)
        scene.autoresizingMask = [.width, .height]
        v.addSubview(scene)
    }
}

private struct Preview: View {
    @EnvironmentObject var model: PanelModel
    let saver: Library.Saver
    let palette: String
    var body: some View {
        LivePreview(key: model.previewKey(saver, palette)) { frame in
            Afterburner(frame: frame, palette: model.palette(palette), logo: saver.logo, title: saver.title)
        }
        .frame(width: 300, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08)))
    }
}

// MARK: screensavers

struct ScreensaversPage: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        let s = model.saver
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Screensavers", detail: "Pick the one that plays, or make your own with any word, logo and colour.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.library.savers) { saver in
                        Tile(title: saver.name, selected: saver.id == model.saverID, inUse: saver.id == model.library.active) {
                            Swatch(palette: model.palette(saver.palette))
                        }
                        .onTapGesture { model.saverID = saver.id; model.colorID = saver.palette }
                        .onTapGesture(count: 2) { model.saverID = saver.id; model.use(saver.id) }
                    }
                    AddTile(help: "New screensaver (a copy of this one)") { model.addSaver() }
                }
                .padding(2)
            }

            HStack(alignment: .top, spacing: 16) {
                Preview(saver: s, palette: s.palette)
                VStack(alignment: .leading, spacing: 11) {
                    Field(label: "Name") {
                        TextField("Name", text: Binding(get: { model.saver.name }, set: { v in model.edit { $0.name = v } }))
                            .textFieldStyle(.roundedBorder)
                    }
                    Field(label: "Text") {
                        TextField("MACH", text: Binding(get: { model.saver.text }, set: { v in model.edit { $0.text = String(v.prefix(10)) } }))
                            .textFieldStyle(.roundedBorder)
                    }
                    Field(label: "Logo") {
                        Text(s.logoPath.map { ($0 as NSString).lastPathComponent } ?? "Jet (built in)")
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…") { model.chooseLogo() }.controlSize(.small)
                        if s.logoPath != nil {
                            Button { model.edit { $0.logoPath = nil } } label: { Image(systemName: "arrow.uturn.backward") }
                                .controlSize(.small).help("Back to the built-in jet")
                        }
                    }
                    Field(label: "Colour") {
                        Picker("", selection: Binding(get: { model.saver.palette }, set: { v in model.edit { $0.palette = v } })) {
                            ForEach(model.palettes, id: \.name) { Text($0.title).tag($0.name) }
                        }
                        .labelsHidden()
                    }
                }
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Text up to 10 characters · logos: braille/ASCII .txt or any image")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Delete", symbol: "trash", tint: .red) { model.deleteSaver() }
                    .disabled(s.isDefault)
                PillButton(title: s.id == model.library.active ? "In Use" : "Use", symbol: "checkmark", primary: true) { model.use(s.id) }
                    .disabled(s.id == model.library.active)
            }
        }
    }
}

// MARK: colours

struct ColorsPage: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        let p = model.palette(model.colorID)
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Colors", detail: "Built-in colourways, plus your own. Start from any of them with +.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.palettes, id: \.name) { pal in
                        Tile(title: pal.title, selected: pal.name == model.colorID, inUse: pal.name == model.saver.palette) {
                            Swatch(palette: pal)
                        }
                        .onTapGesture { model.colorID = pal.name }
                    }
                    AddTile(help: "New colourway from this one") { model.addColorway() }
                }
                .padding(2)
            }

            HStack(alignment: .top, spacing: 16) {
                Preview(saver: model.saver, palette: model.colorID)
                if model.colorway != nil {
                    VStack(alignment: .leading, spacing: 9) {
                        Field(label: "Name") {
                            TextField("Name", text: Binding(get: { model.colorway?.name ?? "" }, set: { v in model.editColor { $0.name = v } }))
                                .textFieldStyle(.roundedBorder)
                        }
                        picker("Background", \.background)
                        HStack(spacing: 14) { picker("Jet top", \.jetTop); picker("bottom", \.jetBottom, narrow: true) }
                        HStack(spacing: 14) { picker("Text from", \.textStart); picker("to", \.textEnd, narrow: true) }
                        Field(label: "Camo") {
                            Toggle("", isOn: Binding(get: { model.colorway?.camo ?? false }, set: { v in model.editColor { $0.camo = v } }))
                                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            Text("Paint the text in patches").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(p.title).font(.system(size: 15, weight: .bold))
                        Text("A built-in colourway. Press + to make an editable copy.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Swatch(palette: p).frame(width: 160, height: 44)
                    }
                }
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text("Changes save as you go").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                PillButton(title: "Delete", symbol: "trash", tint: .red) { model.deleteColorway() }
                    .disabled(model.colorway == nil)
                PillButton(title: model.saver.palette == model.colorID ? "On \(model.saver.name)" : "Use on \(model.saver.name)",
                           symbol: "paintbrush.fill", primary: true) { model.applyColor() }
                    .disabled(model.saver.palette == model.colorID)
            }
        }
    }

    private func picker(_ label: String, _ key: WritableKeyPath<Library.Colorway, String>, narrow: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: narrow ? nil : 64, alignment: .leading)
            ColorPicker("", selection: hexBinding({ model.colorway?[keyPath: key] ?? "#000000" },
                                                  { v in model.editColor { $0[keyPath: key] = v } }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }
}

// MARK: settings

struct SettingsPage: View {
    @EnvironmentObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Settings", detail: "When Mach Saver keeps your Mac awake, and when the screensaver shows.")
            PanelSection(title: "Keep awake") {
                Picker("", selection: Binding(get: { model.keepAwake }, set: { model.setKeepAwake($0) })) {
                    ForEach(KeepAwake.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("While agents run: only while an agent is working. Otherwise your Mac sleeps as usual.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            PanelSection(title: "Screensaver when you're away for") {
                Picker("", selection: Binding(get: { model.idleMinutes }, set: { model.setIdle($0) })) {
                    ForEach([1.0, 2, 5, 10, 15, 0], id: \.self) { m in Text(m == 0 ? "Never" : "\(Int(m)) min").tag(m) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text("While an agent works. Or show it any time with your AeroSpace shortcut (mach-saver://show).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            PanelSection(title: "Startup") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login").font(.system(size: 13, weight: .medium))
                        Text("Waits in the menu bar until you need it").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            Spacer(minLength: 0)
        }
    }
}
