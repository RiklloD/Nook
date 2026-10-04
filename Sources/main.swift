import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainActor.assumeIsolated { NotchWindowController() }

        // NOOK_DEMO=media|agents opens the panel for 2.5 s without touching the pointer (for screenshots).
        if let demo = ProcessInfo.processInfo.environment["NOOK_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                MainActor.assumeIsolated {
                    controller.model.open()
                    controller.model.switchTab(demo == "agents" ? .agents : .media)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                    MainActor.assumeIsolated { controller.model.close() }
                }
            }
        }
    }

    /// Launching Nook again (Tinycast, Spotlight, Finder) while it runs opens the notch panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { controller.model.openFromLaunch() }
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
