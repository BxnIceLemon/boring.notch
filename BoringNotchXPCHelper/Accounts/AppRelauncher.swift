//
//  AppRelauncher.swift
//  BoringNotchXPCHelper
//
//  Quits and reopens ChatGPT.app / Claude.app around a login switch. Uses a normal quit request
//  (the app can save its state); never force-kills. Runs in the helper because the sandboxed app
//  cannot terminate other apps.
//

import AppKit

enum AppRelauncher {
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Asks every instance to quit and waits until all are gone. Returns false on timeout.
    @discardableResult
    static func quit(_ bundleID: String, timeout: TimeInterval = 20) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return true }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return true }
            usleep(200_000)
        }
        return false
    }

    static func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Whether any `codex` CLI process is running (those also need a restart after a switch).
    static func codexCLIRunning() -> Bool {
        guard let result = try? Subprocess.run("/usr/bin/pgrep", ["-x", "codex"], timeout: 3) else { return false }
        return result.status == 0
    }
}
