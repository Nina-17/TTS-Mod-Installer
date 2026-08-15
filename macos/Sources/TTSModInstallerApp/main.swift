import AppKit
import TTSModInstallerCore

let application = NSApplication.shared
application.appearance = NSAppearance(named: .aqua)
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
