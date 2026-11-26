//
//  SystemSettings.swift
//  TapEQ
//

import AppKit

enum SystemSettings {
    /// Opens Privacy & Security at the audio recording section, where the
    /// "System Audio Recording Only" list lives.
    static func openAudioCapturePrivacy() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
