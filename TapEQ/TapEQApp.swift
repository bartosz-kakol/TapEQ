//
//  TapEQApp.swift
//  TapEQ
//
//  Created by Bartosz Kąkol on 25/11/2026.
//

import AppKit

/// The app is AppKit at the top: a status item with a native menu, and a
/// main window created on demand. No SwiftUI scene is needed for either.
@main
enum TapEQApp {
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private lazy var mainWindow = MainWindowController(model: model)
    private var statusMenu: StatusMenuController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // As the host of the unit tests the app stays inert: no audio, no UI.
        guard !AppEnvironment.isRunningTests else { return }
        installMainMenu()
        installSignalHandlers()
        model.start()
        statusMenu = StatusMenuController(model: model) { [weak self] section in
            self?.mainWindow.show(section: section)
        }
        #if DEBUG
        if DebugSnapshots.isRequested {
            DebugSnapshots.run(model: model)
            return
        }
        if let name = ProcessInfo.processInfo.environment["TAPEQ_OPEN_SECTION"],
           let section = MainWindowView.Section(rawValue: name) {
            mainWindow.show(section: section)
            return
        }
        #endif
        if model.isFirstLaunch {
            // Nothing is set up yet; the menu bar icon alone would be easy
            // to miss.
            showMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutDown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func showMainWindow() {
        mainWindow.show()
    }

    /// An app that lives in the menu bar gets no menu bar of its own, but
    /// its windows still rely on the standard menu items for ⌘Q, ⌘W and the
    /// editing shortcuts in text fields.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TapEQ", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TapEQ", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TapEQ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// `kill`, a logout and Ctrl-C do not go through `applicationWillTerminate`.
    /// Catch them so the taps are destroyed in an orderly way first. (After a
    /// force quit or a crash the system destroys them: taps and private
    /// aggregates do not outlive the process that made them.)
    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.model.shutDown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
