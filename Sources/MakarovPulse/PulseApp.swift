import AppKit
import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

@main
struct PulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Makarov Pulse", id: "monitor") { MonitorWindow() }
            .defaultSize(width: 1240, height: 760)
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("About Makarov Pulse") {
                        NSApp.orderFrontStandardAboutPanel(options: [
                            .applicationName: "Makarov Pulse",
                            .applicationVersion: "0.1.0",
                            .credits: NSAttributedString(string: "Developed by Mykhailo Makarov")
                        ])
                    }
                }
            }
    }
}
