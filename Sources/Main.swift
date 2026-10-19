import SwiftUI
import AppKit
import Combine

// App entry: NSApp + a single window hosting the SwiftUI UI.
//
// No MainMenu.xib here, so @main on the delegate is not enough — NSApplicationMain
// would never instantiate it. Create the app and delegate explicitly instead.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        NSApp.activate(ignoringOtherApps: true)

        let hub = PrinterHub.shared
        let content = ContentView(hub: hub)
        let hosting = NSHostingView(rootView: content)
        // Stop SwiftUI from propagating its ideal/min/max sizes onto the window: those
        // constraints would force the window to grow to the content's ideal height.
        hosting.sizingOptions = []

        // Host the SwiftUI view inside a plain container so AppKit resizes it with the
        // window; assigning an NSHostingView directly as contentView leaves it at its
        // creation size when the window is shrunk.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 840))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 840),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.contentView = container
        w.setContentSize(NSSize(width: 1180, height: 840))
        w.center()
        w.isReleasedWhenClosed = false
        w.title = "EufyMake Sender"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .visible
        w.minSize = Self.minSize(for: AppSettings.shared.limitWindowSize)
        w.backgroundColor = .windowBackgroundColor
        w.delegate = self
        w.makeKeyAndOrderFront(nil)
        window = w

        // Keep the window's minimum size in sync with the Settings toggle.
        AppSettings.shared.$limitWindowSize
            .receive(on: RunLoop.main)
            .sink { [weak self] limit in
                guard let w = self?.window else { return }
                let size = Self.minSize(for: limit)
                w.minSize = size
                w.contentMinSize = size
                // Enabling the limit should also bring an already-small window back
                // up to the minimum so the panels are readable again.
                if limit {
                    let frame = w.frame
                    let needed = w.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
                    if frame.width < needed.width || frame.height < needed.height {
                        var f = frame
                        f.size.width = Swift.max(frame.width, needed.width)
                        f.size.height = Swift.max(frame.height, needed.height)
                        w.setFrame(f, display: true, animate: true)
                    }
                }
                NSLog("[settings] window limit %@ → min %.0fx%.0f", limit ? "on" : "off", size.width, size.height)
            }
            .store(in: &cancellables)
    }

    static func minSize(for limited: Bool) -> NSSize {
        limited ? AppSettings.limitedMinSize : AppSettings.unlimitedMinSize
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PrinterHub.shared.shutdown()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About EufyMake Sender",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(AppDelegate.openSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide EufyMake Sender", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit EufyMake Sender", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}

// Enforce the resize limit during user drags. `minSize` alone is sometimes lost when
// SwiftUI re-lays out the hosting view, so clamp the proposed frame every time.
extension AppDelegate: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedContent = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let minContent = Self.minSize(for: AppSettings.shared.limitWindowSize)
        let content = NSSize(width: Swift.max(proposedContent.width, minContent.width),
                             height: Swift.max(proposedContent.height, minContent.height))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }
}

@main
struct EufyMakeSenderApp {
    // NSApplication.delegate is weak; keep a strong reference for the app's lifetime.
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
