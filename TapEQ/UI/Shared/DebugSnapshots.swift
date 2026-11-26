//
//  DebugSnapshots.swift
//  TapEQ
//
//  Development aid, Debug builds only: renders the main screens to PNG files
//  and quits. Run with TAPEQ_SNAPSHOT_DIR set to an existing folder.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DebugSnapshots {
    private static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["TAPEQ_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var isRequested: Bool { directory != nil }

    private static var windows: [NSWindow] = []

    static func run(model: AppModel) {
        guard let directory else { return }
        // Let the engine find the devices and the playing apps first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            writeMenuBarIcons(to: directory.appendingPathComponent("icons.png"))
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                capture(
                    StatusMenuHeader().environment(model),
                    size: nil, appearance: appearance,
                    to: directory.appendingPathComponent("menubar-\(suffix).png")
                )
                for section in MainWindowView.Section.allCases {
                    capture(
                        MainWindowView(navigation: MainWindowNavigation(section: section)).environment(model),
                        size: NSSize(width: 1_020, height: 700), appearance: appearance,
                        to: directory.appendingPathComponent("main-\(section.rawValue)-\(suffix).png")
                    )
                }
            }
            // Give the lazily laid-out views a moment, then write and leave.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                for window in windows { write(window) }
                model.shutDown()
                exit(0)
            }
        }
    }

    private static var destinations: [ObjectIdentifier: URL] = [:]

    /// The three menu bar glyphs side by side, enlarged, as they look on a
    /// light and on a dark menu bar.
    private static func writeMenuBarIcons(to url: URL) {
        let variants: [MenuBarIcon.Variant] = [.normal, .overrideActive, .bypassed]
        let scale: CGFloat = 6
        let side = MenuBarIcon.image(.normal).size.width
        let cell = side * scale + 24
        let image = NSImage(size: NSSize(width: cell * 3, height: cell * 2), flipped: false) { _ in
            for (row, background) in [NSColor.white, NSColor(white: 0.12, alpha: 1)].enumerated() {
                background.setFill()
                NSRect(x: 0, y: CGFloat(row) * cell, width: cell * 3, height: cell).fill()
                for (column, variant) in variants.enumerated() {
                    let glyph = MenuBarIcon.image(variant).copy() as! NSImage
                    glyph.isTemplate = false
                    let rect = NSRect(x: CGFloat(column) * cell + 12, y: CGFloat(row) * cell + 12, width: side * scale, height: side * scale)
                    if row == 1 {
                        // Template images are black with alpha; invert for the dark bar.
                        let tinted = NSImage(size: glyph.size, flipped: false) { bounds in
                            glyph.draw(in: bounds)
                            NSColor.white.set()
                            bounds.fill(using: .sourceAtop)
                            return true
                        }
                        tinted.draw(in: rect)
                    } else {
                        glyph.draw(in: rect)
                    }
                }
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func capture<Content: View>(_ view: Content, size: NSSize?, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingController(rootView: view)
        hosting.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = size == nil
            ? [.borderless]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.appearance = NSAppearance(named: appearance)
        window.toolbarStyle = .unified
        if let size {
            window.setContentSize(size)
        } else {
            window.setContentSize(hosting.view.fittingSize)
        }
        // Far off any screen: this is only for drawing into a bitmap.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        windows.append(window)
        destinations[ObjectIdentifier(window)] = url
    }

    private static func write(_ window: NSWindow) {
        guard let url = destinations[ObjectIdentifier(window)],
              let view = window.contentView?.superview ?? window.contentView
        else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
