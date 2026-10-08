import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: NotchWindowController!
    var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller = NotchWindowController()
            settings = SettingsWindowController(model: controller.model)
            controller.model.showSettings = { [weak self] in self?.showSettings() }
            controller.model.enableLaunchAtLoginOnce()
        }

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

    /// Launching Nook again (Tinycast, Spotlight, Finder) while it runs opens the notch panel;
    /// launching it once more while the panel shows opens Settings instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated {
            if controller.model.phase == .open { showSettings() } else { controller.model.openFromLaunch() }
        }
        return false
    }

    @MainActor private func showSettings() {
        controller.model.close()
        settings.show()
    }
}

// Run by Claude Code's hooks (tools/claude-hooks.js), not as the app.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--claude-hook" {
    ClaudeHook.run(pid: CommandLine.arguments[2])
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
