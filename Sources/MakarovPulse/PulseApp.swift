import AppKit
import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM keeps its resources in a separate bundle when run as an executable.
        let resources = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        if let url = resources.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
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
                            .applicationIcon: NSApp.applicationIconImage as Any,
                            .applicationName: "Makarov Pulse",
                            .applicationVersion: Display.version,
                            .credits: NSAttributedString(string: "Developed by Mykhailo Makarov")
                        ])
                    }
                }
            }
    }
}
