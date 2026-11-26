//
//  FrequencyResponseGraph.swift
//  TapEQ
//
//  The curve of a preset on a log frequency axis, with one draggable handle
//  per band: drag sideways for frequency, up and down for gain, and scroll
//  (or Option-drag) for Q.
//

import AppKit
import SwiftUI

/// Maps between plot coordinates and frequency / decibels.
struct GraphScale {
    static let frequencyRange = EQLimits.frequency
    static let gainRange: ClosedRange<Double> = -24...24

    let plot: CGRect

    func x(forFrequency frequency: Double) -> CGFloat {
        let low = log10(Self.frequencyRange.lowerBound)
        let high = log10(Self.frequencyRange.upperBound)
        let clamped = min(max(frequency, Self.frequencyRange.lowerBound), Self.frequencyRange.upperBound)
        return plot.minX + CGFloat((log10(clamped) - low) / (high - low)) * plot.width
    }

    func frequency(atX x: CGFloat) -> Double {
        let low = log10(Self.frequencyRange.lowerBound)
        let high = log10(Self.frequencyRange.upperBound)
        let fraction = Double(min(max((x - plot.minX) / plot.width, 0), 1))
        return pow(10, low + fraction * (high - low))
    }

    func y(forGain gain: Double) -> CGFloat {
        let clamped = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        let fraction = (clamped - Self.gainRange.lowerBound) / (Self.gainRange.upperBound - Self.gainRange.lowerBound)
        return plot.maxY - CGFloat(fraction) * plot.height
    }

    func gain(atY y: CGFloat) -> Double {
        let fraction = Double(min(max((plot.maxY - y) / plot.height, 0), 1))
        return Self.gainRange.lowerBound + fraction * (Self.gainRange.upperBound - Self.gainRange.lowerBound)
    }

    /// Where the handle of a band sits. Bands without gain sit on the 0 dB line.
    func handlePosition(for band: Band) -> CGPoint {
        CGPoint(x: x(forFrequency: band.frequency), y: y(forGain: band.type.usesGain ? band.gain : 0))
    }
}

/// Forwards scroll-wheel events to a handler while installed. SwiftUI on
/// macOS 14 has no scroll-wheel gesture of its own.
@MainActor
final class ScrollWheelMonitor {
    /// Returns true when the event was used and should go no further.
    var handler: ((NSEvent) -> Bool)?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            (self?.handler?(event) ?? false) ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

struct FrequencyResponseGraph: View {
    let preset: Preset
    let isEditable: Bool
    @Binding var selectedBandID: UUID?
    /// Called with the edited preset on every change.
    let onChange: (Preset) -> Void

    /// The band being dragged and how it looked when the drag began. The
    /// outer optional is nil while no drag is in progress; the inner one is
    /// nil for a drag that did not start on a handle.
    @State private var drag: Band??
    @State private var hoverLocation: CGPoint?
    @State private var scrollMonitor = ScrollWheelMonitor()

    static let bandColors: [Color] = (0..<EQLimits.maxBands).map { index in
        Color(hue: (Double(index) * 0.618).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.88)
    }

    private static let handleRadius: CGFloat = 9
    private static let majorFrequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private static let minorFrequencies: [Double] = [30, 40, 60, 70, 80, 90, 300, 400, 600, 700, 800, 900,
                                                     3_000, 4_000, 6_000, 7_000, 8_000, 9_000]
    private static let curveFrequencies = EQCurve.logFrequencies(count: 320)

    var body: some View {
        GeometryReader { geometry in
            let scale = GraphScale(plot: CGRect(
                x: 38, y: 10,
                width: max(10, geometry.size.width - 50),
                height: max(10, geometry.size.height - 34)
            ))
            // Keep the scroll handler in step with what is on screen.
            let _ = scrollMonitor.handler = { event in handleScroll(event, scale: scale) }

            Canvas { context, _ in
                drawGrid(in: &context, scale: scale)
                drawCurves(in: &context, scale: scale)
                drawHandles(in: &context, scale: scale)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(scale: scale))
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    addBand(at: value.location, scale: scale)
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { scrollMonitor.start() }
        .onDisappear { scrollMonitor.stop() }
        .accessibilityLabel("Frequency response of \(preset.name)")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let active = preset.bands.filter(\.isEnabled)
        guard !active.isEmpty else { return "Flat" }
        return active.map { band in
            let gain = band.type.usesGain ? String(format: ", %+.1f decibels", band.gain) : ""
            return "\(band.type.displayName) at \(Self.frequencyLabel(band.frequency)) hertz\(gain)"
        }.joined(separator: "; ")
    }

    // MARK: Drawing

    private func drawGrid(in context: inout GraphicsContext, scale: GraphScale) {
        let plot = scale.plot
        let minor = Color.primary.opacity(0.05)
        let major = Color.primary.opacity(0.12)

        for frequency in Self.minorFrequencies {
            let x = scale.x(forFrequency: frequency)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(minor), lineWidth: 1)
        }
        for frequency in Self.majorFrequencies {
            let x = scale.x(forFrequency: frequency)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                           with: .color(major), lineWidth: 1)
            context.draw(
                Text(Self.frequencyLabel(frequency)).font(.system(size: 9.5)).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plot.maxY + 11)
            )
        }
        for gain in stride(from: -24.0, through: 24, by: 6) {
            let y = scale.y(forGain: gain)
            context.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: y)); $0.addLine(to: CGPoint(x: plot.maxX, y: y)) },
                           with: .color(gain == 0 ? Color.primary.opacity(0.3) : major), lineWidth: 1)
            context.draw(
                Text(gain == 0 ? "0 dB" : String(format: "%+.0f", gain)).font(.system(size: 9.5)).foregroundStyle(.secondary),
                at: CGPoint(x: plot.minX - 6, y: y),
                anchor: .trailing
            )
        }
    }

    private func curvePath(_ values: [Double], scale: GraphScale) -> Path {
        var path = Path()
        for (index, frequency) in Self.curveFrequencies.enumerated() {
            let point = CGPoint(x: scale.x(forFrequency: frequency), y: scale.y(forGain: values[index]))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func drawCurves(in context: inout GraphicsContext, scale: GraphScale) {
        let plot = scale.plot
        var clipped = context
        clipped.clip(to: Path(plot))

        // The selected band on its own, as a soft fill.
        if let index = preset.bands.firstIndex(where: { $0.id == selectedBandID }), preset.bands[index].isEnabled {
            let values = EQCurve.response(bands: [preset.bands[index]], at: Self.curveFrequencies)
            var fill = curvePath(values, scale: scale)
            fill.addLine(to: CGPoint(x: plot.maxX, y: scale.y(forGain: 0)))
            fill.addLine(to: CGPoint(x: plot.minX, y: scale.y(forGain: 0)))
            fill.closeSubpath()
            clipped.fill(fill, with: .color(Self.bandColors[index % Self.bandColors.count].opacity(0.22)))
        }

        // The bands without the preamp, faintly, when the preamp moves the curve.
        let bandsOnly = EQCurve.response(bands: preset.bands, at: Self.curveFrequencies)
        if abs(preset.preampDB) > 0.05 {
            clipped.stroke(curvePath(bandsOnly, scale: scale), with: .color(Color.primary.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // What is actually applied: bands plus preamp.
        let applied = bandsOnly.map { $0 + preset.preampDB }
        clipped.stroke(curvePath(applied, scale: scale), with: .color(.accentColor),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    private func drawHandles(in context: inout GraphicsContext, scale: GraphScale) {
        for (index, band) in preset.bands.enumerated() {
            let center = scale.handlePosition(for: band)
            let radius = Self.handleRadius
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let color = Self.bandColors[index % Self.bandColors.count]
            let isSelected = band.id == selectedBandID

            if isSelected {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color.opacity(0.6)), lineWidth: 2)
            }
            if band.isEnabled {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.7)), lineWidth: 1.5)
            }
            context.draw(
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(band.isEnabled ? Color.black.opacity(0.75) : Color.secondary),
                at: center
            )
        }
    }

    static func frequencyLabel(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            let thousands = frequency / 1_000
            return thousands == thousands.rounded() ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
        }
        return "\(Int(frequency.rounded()))"
    }

    // MARK: Interaction

    private func bandIndex(near point: CGPoint, within distance: CGFloat, scale: GraphScale) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, band) in preset.bands.enumerated() {
            let handle = scale.handlePosition(for: band)
            let d = hypot(handle.x - point.x, handle.y - point.y)
            // On a tie the later handle wins: it is the one drawn on top.
            if d <= distance, best == nil || d <= best!.distance {
                best = (index, d)
            }
        }
        return best?.index
    }

    private func dragGesture(scale: GraphScale) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEditable else { return }
                if drag == nil {
                    if let index = bandIndex(near: value.startLocation, within: Self.handleRadius + 6, scale: scale) {
                        drag = .some(preset.bands[index])
                        selectedBandID = preset.bands[index].id
                    } else {
                        drag = .some(nil)
                    }
                }
                guard case .some(.some(let original)) = drag,
                      let index = preset.bands.firstIndex(where: { $0.id == original.id })
                else { return }

                var band = preset.bands[index]
                let adjustsQ = NSEvent.modifierFlags.contains(.option)
                if adjustsQ || !band.type.usesGain {
                    // Up narrows the band, down widens it: one octave of Q
                    // per 60 points.
                    band.q = original.q * pow(2, Double(-value.translation.height) / 60)
                }
                if !adjustsQ {
                    band.frequency = Self.rounded(frequency: scale.frequency(atX: value.location.x))
                    if band.type.usesGain {
                        band.gain = (scale.gain(atY: value.location.y) * 10).rounded() / 10
                    }
                }
                apply(band.clamped(), at: index)
            }
            .onEnded { _ in
                drag = nil
            }
    }

    private func handleScroll(_ event: NSEvent, scale: GraphScale) -> Bool {
        guard isEditable, let location = hoverLocation, event.scrollingDeltaY != 0 else { return false }
        let index = bandIndex(near: location, within: Self.handleRadius + 14, scale: scale)
            ?? preset.bands.firstIndex { $0.id == selectedBandID }
        guard let index else { return false }
        var band = preset.bands[index]
        // A trackpad reports many small deltas, a wheel a few large ones.
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 12
        band.q = ((band.q * pow(2, Double(step))) * 100).rounded() / 100
        selectedBandID = band.id
        apply(band.clamped(), at: index)
        return true
    }

    private func addBand(at point: CGPoint, scale: GraphScale) {
        guard isEditable, preset.bands.count < EQLimits.maxBands, scale.plot.contains(point),
              bandIndex(near: point, within: Self.handleRadius + 6, scale: scale) == nil
        else { return }
        let band = Band(
            type: .peak,
            frequency: Self.rounded(frequency: scale.frequency(atX: point.x)),
            gain: (scale.gain(atY: point.y) * 10).rounded() / 10,
            q: 1
        )
        var edited = preset
        edited.bands.append(band)
        selectedBandID = band.id
        onChange(edited)
    }

    private func apply(_ band: Band, at index: Int) {
        guard preset.bands[index] != band else { return }
        var edited = preset
        edited.bands[index] = band
        onChange(edited)
    }

    /// Rounds to three significant digits, which is as fine as anyone can
    /// place a handle by hand.
    static func rounded(frequency: Double) -> Double {
        guard frequency > 0 else { return frequency }
        let magnitude = pow(10, floor(log10(frequency)) - 2)
        return (frequency / magnitude).rounded() * magnitude
    }
}
