import AppKit
import ServiceManagement
import SwiftUI

/// A small settings window, opened by launching Nook while its panel is already showing
/// (or from the notch's right-click menu). Built on first use and kept for the session.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: NotchModel

    init(model: NotchModel) { self.model = model }

    func show() {
        let window = self.window ?? make()
        self.window = window
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                    backing: .buffered, defer: true)
        window.title = "Nook Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.setContentSize(window.contentView!.fittingSize)
        return window
    }
}

/// ⌘W and ⌘Q work without a main menu (Nook is a UI element, so it never shows one).
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w": performClose(nil); return true
        case "q": NSApp.terminate(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nook").font(.headline)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Row("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                if model.launchAtLoginNeedsApproval {
                    Button("Allow in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link).font(.caption)
                }
                Row("Open on hover", detail: "Off: click the notch to open it.", isOn: $model.openOnHover)
            }

            Text("Open Nook again while its panel shows to come back here, or right-click the notch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Quit Nook") { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 320)
    }
}

private struct Row: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}
