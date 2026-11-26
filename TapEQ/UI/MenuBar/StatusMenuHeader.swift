//
//  StatusMenuHeader.swift
//  TapEQ
//
//  The top of the menu bar menu: the current output with its effective
//  preset, and one large switch that turns all EQ off and back on.
//

import SwiftUI

struct StatusMenuHeader: View {
    @Environment(AppModel.self) private var model

    private var engine: AudioEngine { model.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            outputRow
            EQPowerTile()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .frame(minWidth: StatusMenuController.width, maxWidth: .infinity, alignment: .leading)
    }

    private var outputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: engine.currentDevice?.symbolName ?? "speaker.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.currentDevice?.name ?? "No Output Device")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !model.bypassAll, engine.deviceResolution.source == .deviceOverride {
                        Badge(text: "Override", color: .orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        guard engine.currentDevice != nil else { return "Connect an output to use TapEQ" }
        if model.bypassAll { return "EQ is off" }
        let resolution = engine.deviceResolution
        if resolution.presetID == nil { return "No preset" }
        return "Preset: \(model.presetName(resolution.presetID))"
    }
}

/// A Control Center style tile: the whole tile is the button.
private struct EQPowerTile: View {
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    private var isOn: Bool { !model.bypassAll }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                model.bypassAll.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(isOn ? "Equalizer On" : "Equalizer Off")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isOn ? "Click to play everything unequalized" : "Audio plays unchanged. Click to turn on.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TileButtonStyle(isOn: isOn, isHovered: isHovered))
        .onHover { isHovered = $0 }
        .accessibilityLabel("Equalizer")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(isOn ? "Turns all EQ off" : "Turns EQ back on")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct TileButtonStyle: ButtonStyle {
    let isOn: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let boost = configuration.isPressed ? 2.0 : (isHovered ? 1.0 : 0.0)
        return configuration.label
            .background(
                shape.fill(isOn
                    ? Color.accentColor.opacity(0.16 + 0.06 * boost)
                    : Color.primary.opacity(0.06 + 0.04 * boost))
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
