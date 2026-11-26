//
//  MainWindowView.swift
//  TapEQ
//
//  The main window: a sidebar with the four sections and their content.
//

import AppKit
import SwiftUI

struct MainWindowView: View {
    enum Section: String, CaseIterable, Identifiable {
        case presets, devices, apps, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .presets: return "Presets"
            case .devices: return "Output Devices"
            case .apps: return "Apps"
            case .settings: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .presets: return "slider.horizontal.3"
            case .devices: return "hifispeaker.2"
            case .apps: return "app.badge"
            case .settings: return "gearshape"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Bindable var navigation: MainWindowNavigation

    private var section: Section? { navigation.section }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $navigation.section) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if !model.loadWarnings.isEmpty {
                    warnings
                }
                switch section ?? .presets {
                case .presets: PresetsView()
                case .devices: DevicesView()
                case .apps: AppsView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle((section ?? .presets).title)
        }
        .frame(minWidth: 900, minHeight: 580)
    }

    private var warnings: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.loadWarnings, id: \.self) { warning in
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Dismiss") { model.dismissLoadWarnings() }
        }
        .font(.callout)
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }
}

/// Which section the main window shows. Kept outside the view so the menu
/// bar can switch the section of a window that is already open.
@MainActor
@Observable
final class MainWindowNavigation {
    var section: MainWindowView.Section?

    init(section: MainWindowView.Section = .presets) {
        self.section = section
    }
}

/// Owns the main window. The window is created on demand and kept, so
/// reopening it brings back the same state.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let navigation = MainWindowNavigation()
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    /// Shows the window, on the given section if one is given.
    func show(section: MainWindowView.Section? = nil) {
        if let section { navigation.section = section }
        if window == nil {
            let hosting = NSHostingController(
                rootView: MainWindowView(navigation: navigation)
                    .environment(model)
            )
            // Let the split view put its title and sidebar button in the
            // window's toolbar, as it would in a SwiftUI scene.
            hosting.sceneBridgingOptions = [.title, .toolbars]
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            newWindow.title = "TapEQ"
            newWindow.toolbarStyle = .unified
            newWindow.setContentSize(NSSize(width: 1_020, height: 680))
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            newWindow.setFrameAutosaveName("TapEQMainWindow")
            window = newWindow
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // An app without a Dock icon is not activated by showing a window,
        // and since macOS 14 activation is a request the system may turn
        // down. Order the window in regardless, so it never opens behind the
        // app that was in front.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Auditioning lasts only while the editor is open.
        model.setAudition(nil)
    }
}
