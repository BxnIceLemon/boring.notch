//
//  LoginProcess.swift
//  BoringNotchXPCHelper
//
//  A CLI sign-in (`codex login`, `claude auth login`) running against a private temporary config
//  directory, so adding an account never signs the current login out. Signing out revokes that
//  account's tokens; a separate sign-in leaves the current one alone.
//
//  The sign-in takes minutes, so callers split it into start / poll / cancel requests and the
//  helper's serial queue stays free in between. Sessions are only touched on AccountsService.queue.
//

import Foundation

final class LoginProcess {
    let id = UUID().uuidString
    let home: URL
    let process = Process()
    let started = Date()
    private let input = Pipe()
    private let lock = NSLock()
    private var buffer = ""

    static let timeout: TimeInterval = 15 * 60

    /// Creates `root/<id>` (0700) as the private config directory; `prepare` fills it before launch.
    init(root: URL, executable: String, arguments: [String], environment: (URL) -> [String: String],
         unset: [String] = [], prepare: (URL) throws -> Void) throws {
        try? FileManager.default.removeItem(at: root)   // leftovers of a crashed run
        try PrivateFiles.ensureDirectory(root)
        home = root.appendingPathComponent(id, isDirectory: true)
        try PrivateFiles.ensureDirectory(home)
        try prepare(home)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for key in unset { env.removeValue(forKey: key) }
        for (key, value) in environment(home) { env[key] = value }
        process.environment = env
        process.currentDirectoryURL = home
        process.standardInput = input
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self else { return }
            self.lock.lock(); self.buffer += String(decoding: data, as: UTF8.self); self.lock.unlock()
        }
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: home)
            throw AccountsError("login_failed", "Could not start the sign-in: \(error.localizedDescription)")
        }
    }

    var output: String { lock.lock(); defer { lock.unlock() }; return buffer }
    var isRunning: Bool { process.isRunning }
    var timedOut: Bool { Date().timeIntervalSince(started) > Self.timeout }

    /// Waits until `find` returns a value (e.g. the sign-in URL) or the process exits.
    func wait<T>(seconds: TimeInterval, for find: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = find() { return value }
            if !process.isRunning { return find() }
            usleep(100_000)
        }
        return nil
    }

    /// Types a line into the CLI (an authorization code pasted by the user).
    func send(_ line: String) {
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// Stops the process and deletes the private config directory.
    func finish() {
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning { usleep(50_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: home)
    }

    var lastLine: String? {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    static func firstURL(in text: String, prefix: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix(prefix) }.map(String.init)
    }
}
