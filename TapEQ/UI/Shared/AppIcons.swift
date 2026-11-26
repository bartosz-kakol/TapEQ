//
//  AppIcons.swift
//  TapEQ
//
//  App icons and names looked up through NSWorkspace, cached.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// The icon of an app, by the location of its bundle if that is known
    /// and otherwise by bundle identifier. Falls back to the generic app icon.
    static func icon(bundleID: String, bundleURL: URL? = nil) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let url = bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        // A generic icon may turn into the real one once the app is
        // installed, so only real icons are cached.
        if url != nil { cache[bundleID] = image }
        return image
    }

    /// An app icon at the size of a menu item image.
    static func menuIcon(bundleID: String, bundleURL: URL? = nil) -> NSImage {
        // A copy, so resizing it leaves the shared image alone.
        let image = (icon(bundleID: bundleID, bundleURL: bundleURL).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// The current display name of an app, if it is installed.
    static func displayName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}

/// An app icon at a fixed size.
struct AppIconView: View {
    let bundleID: String
    var bundleURL: URL?
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: AppIcons.icon(bundleID: bundleID, bundleURL: bundleURL))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
