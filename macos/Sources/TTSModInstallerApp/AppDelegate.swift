import AppKit
import TTSModInstallerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?
    private var mainViewController: MainViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        InstallerLogger.cleanStaleData()
        let controller = MainViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "TTS 本地图包安装器"
        window.setContentSize(NSSize(width: 760, height: 680))
        window.minSize = NSSize(width: 680, height: 620)
        window.center()
        let windowController = NSWindowController(window: window)
        self.mainViewController = controller
        self.windowController = windowController
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        mainViewController?.addPackageURLs(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
