//
//  MenuBarIcon.swift
//  TapEQ
//
//  The menu bar glyph. The artwork is the `MenuBarGlyph` template image in
//  the asset catalog; the two state marks are drawn on top of it here, so
//  replacing the artwork keeps them: a dot in the corner while an override
//  is active, and a slash while "Bypass all EQ" is on.
//

import AppKit

@MainActor
enum MenuBarIcon {
    enum Variant: Equatable {
        case normal
        case overrideActive
        case bypassed

        var accessibilityDescription: String {
            switch self {
            case .normal: return "TapEQ"
            case .overrideActive: return "TapEQ, override active"
            case .bypassed: return "TapEQ, bypassed"
            }
        }
    }

    /// The side of the square grid the artwork is drawn on, in points. The
    /// positions of the marks below are given on this grid.
    nonisolated private static let designSize: CGFloat = 22

    private static var cache: [Variant: NSImage] = [:]

    static func image(_ variant: Variant) -> NSImage {
        if let cached = cache[variant] { return cached }

        let artwork = NSImage(named: "MenuBarGlyph")
            ?? NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: designSize, height: designSize))
        let image = NSImage(size: artwork.size, flipped: false) { bounds in
            draw(variant, artwork: artwork, in: bounds)
            return true
        }
        // A template image is used for its alpha only: the menu bar colours
        // it for a light or a dark bar and for the highlighted state.
        image.isTemplate = true
        image.accessibilityDescription = variant.accessibilityDescription
        cache[variant] = image
        return image
    }

    nonisolated private static func draw(_ variant: Variant, artwork: NSImage, in bounds: NSRect) {
        let unit = bounds.width / designSize
        /// A point on the design grid, measured from the top left as in the
        /// artwork's own file.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: bounds.minX + x * unit, y: bounds.maxY - y * unit)
        }

        artwork.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: variant == .bypassed ? 0.45 : 1)

        switch variant {
        case .normal:
            break

        case .overrideActive:
            // The top right corner of the artwork is empty.
            let radius = 2.6 * unit
            let center = point(18.4, 4.8)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()

        case .bypassed:
            let slash = NSBezierPath()
            slash.move(to: point(4.5, 3.5))
            slash.line(to: point(17.5, 18.5))
            slash.lineCapStyle = .round

            // Clear a channel through the artwork first, so the slash reads
            // as a separate stroke rather than merging with the curve.
            if let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .destinationOut
                slash.lineWidth = 4.4 * unit
                NSColor.black.setStroke()
                slash.stroke()
                context.restoreGraphicsState()
            }
            slash.lineWidth = 1.6 * unit
            NSColor.black.setStroke()
            slash.stroke()
        }
    }
}
