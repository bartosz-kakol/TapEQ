//
//  AppIdentity.swift
//  TapEQ
//
//  Works out which app an audio process belongs to. Many apps play sound
//  from helper processes, so the process that holds the audio stream is often
//  not the app the user thinks of.
//

import AppKit
import Darwin
import Foundation

/// The app an audio process is presented as.
struct AppIdentity: Equatable, Sendable {
    /// What the app is listed and overridden under: the owning app's bundle
    /// identifier where one is known, otherwise the process's own.
    let id: String
    let name: String
    /// Location of the app bundle, for its icon.
    let bundleURL: URL?
    /// Every identifier a rule may match this process by.
    let matchIDs: [String]
    /// A note for the UI when the identity needs explaining.
    let note: String?
}

@MainActor
final class AppIdentityResolver {
    /// Audio for Safari and every other WebKit-based app comes from this
    /// shared system process.
    static let webKitAudioBundleID = "com.apple.WebKit.GPU"

    /// Extra identifiers worth suggesting when a rule is created for an app
    /// whose audio is played by a process with an unrelated identifier.
    static func suggestedExtraBundleIDs(forApp bundleID: String) -> [String] {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return [webKitAudioBundleID]
        default: return []
        }
    }

    /// Processes without a bundle are identified by executable name with
    /// this prefix, as in `exec:afplay`.
    static let executablePrefix = "exec:"

    private var cache: [pid_t: (bundleID: String, identity: AppIdentity)] = [:]

    func identity(for process: AudioProcess) -> AppIdentity {
        if let cached = cache[process.pid], cached.bundleID == process.bundleID {
            return cached.identity
        }
        let identity = Self.resolve(process)
        cache[process.pid] = (process.bundleID, identity)
        return identity
    }

    /// Forgets processes that no longer exist.
    func prune(keeping pids: Set<pid_t>) {
        cache = cache.filter { pids.contains($0.key) }
    }

    private static func resolve(_ process: AudioProcess) -> AppIdentity {
        // What the process itself is called, for rules that name it exactly.
        let ownID: String
        if process.bundleID.isEmpty {
            ownID = executableName(of: process.pid).map { executablePrefix + $0 } ?? ""
        } else {
            ownID = process.bundleID
        }

        // A helper belongs to the nearest ancestor that is an app in its own
        // right (one the user can see in the Dock or the menu bar). The same
        // goes for a command-line tool started from a terminal window.
        var pid = process.pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: pid),
               app.activationPolicy != .prohibited,
               let bundleID = app.bundleIdentifier {
                return AppIdentity(
                    id: bundleID,
                    name: app.localizedName ?? bundleID,
                    bundleURL: app.bundleURL,
                    matchIDs: unique([ownID, bundleID]),
                    note: nil
                )
            }
            guard let parent = parentPID(of: pid), parent > 1, parent != pid else { break }
            pid = parent
        }

        if !process.bundleID.isEmpty {
            if process.bundleID == webKitAudioBundleID {
                return AppIdentity(
                    id: process.bundleID,
                    name: "WebKit audio",
                    bundleURL: nil,
                    matchIDs: [process.bundleID],
                    note: "Shared by Safari and every app that shows web content"
                )
            }
            let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: process.bundleID)
            let name = bundleURL.map { FileManager.default.displayName(atPath: $0.path) }
                ?? NSRunningApplication(processIdentifier: process.pid)?.localizedName
                ?? process.bundleID
            return AppIdentity(id: process.bundleID, name: name, bundleURL: bundleURL, matchIDs: [process.bundleID], note: nil)
        }

        // No bundle and no app above it: a background tool.
        let name = executableName(of: process.pid) ?? "Process \(process.pid)"
        let id = ownID.isEmpty ? executablePrefix + name : ownID
        return AppIdentity(id: id, name: name, bundleURL: nil, matchIDs: [id], note: "Command-line tool")
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func executableName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
