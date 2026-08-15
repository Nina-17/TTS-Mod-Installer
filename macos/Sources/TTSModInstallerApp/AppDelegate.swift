import AppKit
import TTSModInstallerCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?
    private var mainViewController: MainViewController?
    private var updateCoordinator: UpdateCoordinator?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        InstallerLogger.cleanStaleData()
        let updateCoordinator = UpdateCoordinator()
        self.updateCoordinator = updateCoordinator
        let controller = MainViewController(updateCoordinator: updateCoordinator)
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
        updateCoordinator.start()
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        mainViewController?.addPackageURLs(urls)
    }

    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
