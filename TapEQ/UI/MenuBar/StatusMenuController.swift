//
//  StatusMenuController.swift
//  TapEQ
//
//  The menu bar icon and its menu. The menu is a native NSMenu, so it lays
//  out, highlights, opens submenus and handles the keyboard like every other
//  menu bar extra. Only the header (the output and the EQ switch) is a
//  SwiftUI view.
//
//  Overrides are chosen from a submenu per target: "Follow Rules" at the top
//  (what the rules give, with no override), then the presets to override
//  with. An override lasts until "Follow Rules" is chosen or TapEQ quits.
//

import AppKit
import Observation
import SwiftUI

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    /// The width of the menu, and of the header inside it.
    nonisolated static let width: CGFloat = 310

    private let model: AppModel
    private let showMainWindow: (MainWindowView.Section?) -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headerItem = NSMenuItem()
    private var isMenuOpen = false
    /// What the items below the header were built from.
    private var shownState: MenuState?

    init(model: AppModel, showMainWindow: @escaping (MainWindowView.Section?) -> Void) {
        self.model = model
        self.showMainWindow = showMainWindow
        super.init()

        let header = NSHostingView(rootView: AnyView(StatusMenuHeader().environment(model)))
        let height = ceil(header.fittingSize.height)
        // From here on the menu sets the width and the header follows it.
        header.sizingOptions = []
        header.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        header.autoresizingMask = [.width]
        headerItem.view = header

        menu.delegate = self
        menu.autoenablesItems = false
        menu.minimumWidth = Self.width
        menu.addItem(headerItem)
        statusItem.menu = menu
        statusItem.button?.imageHugsTitle = true

        trackStatusButton()
    }

    // MARK: Status item

    private func trackStatusButton() {
        withObservationTracking {
            updateStatusButton()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.trackStatusButton() }
            }
        }
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let variant: MenuBarIcon.Variant = model.bypassAll ? .bypassed : (model.hasActiveOverride ? .overrideActive : .normal)
        button.image = MenuBarIcon.image(variant)
        if let text = model.menuBarPresetText {
            button.title = text
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("\(variant.accessibilityDescription), \(text)")
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(variant.accessibilityDescription)
        }
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild(force: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isMenuOpen = false
    }

    // MARK: Building

    /// Rebuilds the items below the header. While the menu is open it
    /// follows the model, so an app that starts playing shows up; it is only
    /// rebuilt when what it shows has changed.
    private func rebuild(force: Bool = false) {
        let state = withObservationTracking {
            MenuState(model: model)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isMenuOpen else { return }
                    self.rebuild()
                }
            }
        }
        guard force || state != shownState else { return }
        shownState = state
        populate(from: state)
    }

    private func populate(from state: MenuState) {
        while menu.items.count > 1 { menu.removeItem(at: 1) }

        if state.isPermissionSuspect {
            menu.addItem(.separator())
            menu.addItem(permissionItem())
        }

        if let output = state.output {
            menu.addItem(.separator())
            menu.addItem(targetItem(output, state: state, isOutput: true))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Playing Now"))
        if state.apps.isEmpty {
            let empty = NSMenuItem(title: "No App Is Playing Audio", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for app in state.apps {
                menu.addItem(targetItem(app, state: state, isOutput: false))
            }
        }

        if state.hasActiveOverride {
            menu.addItem(.separator())
            let clear = ActionMenuItem("Clear All Overrides", symbol: "arrow.uturn.backward") { [model] in
                model.clearAllOverrides()
            }
            clear.toolTip = "Every output and app follows its rules again."
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Open TapEQ…", symbol: "macwindow", key: ",") { [showMainWindow] in
            showMainWindow(nil)
        })
        menu.addItem(ActionMenuItem("Quit TapEQ", symbol: "xmark.circle", key: "q") {
            NSApp.terminate(nil)
        })
    }

    private func permissionItem() -> NSMenuItem {
        let item = ActionMenuItem("TapEQ Isn’t Receiving Audio") {
            SystemSettings.openAudioCapturePrivacy()
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(config)
        item.setSubtitle("Allow it under System Audio Recording, then reopen TapEQ")
        item.toolTip = "Apps are playing, but nothing reaches TapEQ, so nothing is equalized (and nothing is muted). Click to open Privacy & Security."
        return item
    }

    /// The item for the output or one playing app, with its override submenu.
    private func targetItem(_ target: MenuState.Target, state: MenuState, isOutput: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: isOutput ? "Output Preset" : target.name, action: nil, keyEquivalent: "")
        if isOutput {
            item.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        } else {
            item.image = AppIcons.menuIcon(bundleID: target.id, bundleURL: target.bundleURL)
        }
        item.toolTip = target.note

        if target.isOnOtherDevice {
            item.isEnabled = false
            item.setSubtitle("Playing on another output, not equalized")
            return item
        }

        item.setSubtitle(describe(target.resolution, isOutput: isOutput, bypassed: state.bypassAll))
        if target.override != nil {
            item.badge = NSMenuItemBadge(string: "Override")
        }
        item.submenu = overrideMenu(for: target, state: state, isOutput: isOutput)
        return item
    }

    private func overrideMenu(for target: MenuState.Target, state: MenuState, isOutput: Bool) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let overrideTarget = target.overrideTarget

        let follow = ActionMenuItem("Follow Rules") { [model] in
            model.clearOverride(overrideTarget)
        }
        follow.state = target.override == nil ? .on : .off
        follow.setSubtitle(describeRules(target.ruleResolution, isOutput: isOutput))
        submenu.addItem(follow)

        submenu.addItem(.separator())
        submenu.addItem(.sectionHeader(title: "Override With"))
        submenu.addItem(presetChoice("None (No EQ)", presetID: nil, target: target))
        for preset in state.presets where preset.isBuiltIn {
            submenu.addItem(presetChoice(preset.name, presetID: preset.id, target: target))
        }
        let userPresets = state.presets.filter { !$0.isBuiltIn }
        if !userPresets.isEmpty {
            submenu.addItem(.separator())
            for preset in userPresets {
                submenu.addItem(presetChoice(preset.name, presetID: preset.id, target: target))
            }
        }

        submenu.addItem(.separator())
        submenu.addItem(footnote(isOutput
            ? "An override replaces this output’s rule until you\nchoose Follow Rules or quit TapEQ."
            : "An override replaces this app’s rules until you\nchoose Follow Rules or quit TapEQ."))
        let section: MainWindowView.Section = isOutput ? .devices : .apps
        submenu.addItem(ActionMenuItem("Edit Rules…") { [showMainWindow] in
            showMainWindow(section)
        })
        return submenu
    }

    private func presetChoice(_ name: String, presetID: UUID?, target: MenuState.Target) -> NSMenuItem {
        let overrideTarget = target.overrideTarget
        let item = ActionMenuItem(name) { [model] in
            model.setOverride(overrideTarget, presetID: presetID, lifetime: .untilCleared)
        }
        if let current = target.override, current.presetID == presetID {
            item.state = .on
        }
        return item
    }

    private func footnote(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// What a target gets right now, and why.
    private func describe(_ resolution: Resolution, isOutput: Bool, bypassed: Bool) -> String {
        if bypassed { return "EQ is off" }
        let name = resolution.presetID == nil ? "No EQ" : model.presetName(resolution.presetID)
        switch resolution.source {
        case .bypass: return "EQ is off"
        case .none: return isOutput ? "No EQ · No rule for this output" : "No EQ"
        case .appOverride: return name
        case .deviceOverride: return isOutput ? name : "\(name) · Same as output"
        case .appOnDeviceRule, .appRule: return "\(name) · App rule"
        case .deviceRule: return isOutput ? "\(name) · Device rule" : "\(name) · Same as output"
        }
    }

    /// What "Follow Rules" gives.
    private func describeRules(_ resolution: Resolution, isOutput: Bool) -> String {
        let name = resolution.presetID == nil ? "No EQ" : model.presetName(resolution.presetID)
        switch resolution.source {
        case .none: return isOutput ? "No rule for this output: No EQ" : "No rule: No EQ"
        case .appOnDeviceRule, .appRule: return "App rule: \(name)"
        case .deviceRule: return isOutput ? "Device rule: \(name)" : "Same as output: \(name)"
        case .deviceOverride: return "Same as output: \(name)"
        case .bypass, .appOverride: return name
        }
    }
}

// MARK: - Menu state

/// Everything the items below the header show, as a value, so the menu is
/// rebuilt only when one of them changes.
private struct MenuState: Equatable {
    struct Target: Equatable {
        let overrideTarget: Override.Target
        let name: String
        let bundleURL: URL?
        let note: String?
        let isOnOtherDevice: Bool
        /// What the target gets now.
        let resolution: Resolution
        /// What it would get from its rules alone.
        let ruleResolution: Resolution
        let override: Override?

        var id: String {
            switch overrideTarget {
            case .app(let bundleID): return bundleID
            case .device(let uid): return uid
            }
        }
    }

    struct PresetChoice: Equatable {
        let id: UUID
        let name: String
        let isBuiltIn: Bool
    }

    let output: Target?
    let apps: [Target]
    let presets: [PresetChoice]
    let bypassAll: Bool
    let hasActiveOverride: Bool
    let isPermissionSuspect: Bool

    @MainActor
    init(model: AppModel) {
        let engine = model.engine
        output = engine.currentDevice.map { device in
            let target = Override.Target.device(uid: device.uid)
            return Target(
                overrideTarget: target,
                name: device.name,
                bundleURL: nil,
                note: nil,
                isOnOtherDevice: false,
                resolution: engine.deviceResolution,
                ruleResolution: model.ruleResolutionForCurrentDevice(),
                override: model.override(for: target)
            )
        }
        apps = engine.playingApps.map { app in
            let target = Override.Target.app(bundleID: app.id)
            return Target(
                overrideTarget: target,
                name: app.name,
                bundleURL: app.bundleURL,
                note: app.note,
                isOnOtherDevice: app.isOnOtherDevice,
                resolution: app.resolution,
                ruleResolution: model.ruleResolution(for: app),
                override: model.override(for: target)
            )
        }
        presets = model.presets.map { PresetChoice(id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn) }
        bypassAll = model.bypassAll
        hasActiveOverride = model.hasActiveOverride
        isPermissionSuspect = engine.permission == .suspectedDenied
    }
}

// MARK: - Helpers

/// A menu item that runs a closure.
private final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: key)
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func runHandler() {
        MainActor.assumeIsolated { handler() }
    }
}

private extension NSMenuItem {
    /// A second line under the title. Before macOS 14.4 menu items have no
    /// subtitle, so it is appended to the title instead.
    func setSubtitle(_ text: String) {
        if #available(macOS 14.4, *) {
            subtitle = text
        } else {
            title = "\(title) — \(text)"
        }
    }
}
