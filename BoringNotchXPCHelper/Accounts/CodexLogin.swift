//
//  CodexLogin.swift
//  BoringNotchXPCHelper
//
//  Adds a Codex account without touching the current login. Signing out in ChatGPT revokes that
//  account's tokens, so instead of "sign out, sign in, save", we run ChatGPT's own `codex login`
//  against a private temporary CODEX_HOME. The browser sign-in lands there, the fresh login is
//  saved into the account store, and the temporary directory is deleted. ~/.codex is never read
//  or written by this flow.
//
//  The login runs for minutes, so it is split into start / poll / cancel requests: the helper's
//  serial queue stays free for usage polling in between.
//

import AppKit
import Foundation

final class CodexLogin {
    private final class Session {
        let process: Process
        let home: URL
        let started = Date()
        private let lock = NSLock()
        private var buffer = ""
        init(process: Process, home: URL) { self.process = process; self.home = home }
        func append(_ text: String) { lock.lock(); buffer += text; lock.unlock() }
        var output: String { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    private static let timeout: TimeInterval = 15 * 60
    private var sessions: [String: Session] = [:]   // only touched on AccountsService.queue
    private let accounts: CodexAccounts

    init(accounts: CodexAccounts) { self.accounts = accounts }

    private var loginRoot: URL { AccountPaths.store.appendingPathComponent("codex-login", isDirectory: true) }

    // MARK: - Start

    /// Starts `codex login` in a fresh CODEX_HOME and returns the sign-in URL. The browser is not
    /// opened here: the app shows the link so it can also be pasted into a private window.
    func start() throws -> JSONObject {
        cancelAll()
        try? FileManager.default.removeItem(at: loginRoot)   // leftovers of a crashed run
        guard let codex = Self.codexBinary() else {
            throw AccountsError("codex_cli_missing", "Could not find the codex command that comes with ChatGPT.")
        }
        let id = UUID().uuidString
        let home = loginRoot.appendingPathComponent(id, isDirectory: true)
        try PrivateFiles.ensureDirectory(loginRoot)
        try PrivateFiles.ensureDirectory(home)
        // File store, so the login lands in home/auth.json instead of the Keychain.
        try PrivateFiles.atomicWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8),
                                     to: home.appendingPathComponent("config.toml"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = ["login"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path
        env["BROWSER"] = "/usr/bin/true"        // we open (or copy) the link ourselves
        process.environment = env
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let session = Session(process: process, home: home)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { session.append(String(decoding: data, as: UTF8.self)) }
        }
        do { try process.run() } catch {
            try? FileManager.default.removeItem(at: home)
            throw AccountsError("codex_login_failed", "Could not start codex login: \(error.localizedDescription)")
        }
        sessions[id] = session

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let url = Self.loginURL(in: session.output) { return ["loginId": id, "url": url] }
            if !process.isRunning { break }
            usleep(100_000)
        }
        let output = session.output
        cancel(id)
        if output.contains("Address already in use") || output.contains("address in use") {
            throw AccountsError("codex_login_port_busy", "Another sign-in is already waiting on port 1455.")
        }
        throw AccountsError("codex_login_failed", Self.lastLine(output) ?? "codex login did not start")
    }

    // MARK: - Poll / cancel

    /// {"state": "pending"} while the browser sign-in is open; {"state": "done", "account": …,
    /// "alreadySaved": Bool} once it finished and was saved; {"state": "failed", "message": …}.
    func poll(_ id: String) throws -> JSONObject {
        guard let session = sessions[id] else { return ["state": "failed", "message": "sign-in was cancelled"] }
        let authURL = session.home.appendingPathComponent("auth.json")
        if session.process.isRunning {
            if Date().timeIntervalSince(session.started) > Self.timeout {
                cancel(id)
                return ["state": "failed", "code": "codex_login_timeout"]
            }
            return ["state": "pending"]
        }
        defer { cleanUp(id) }
        guard let auth = try JSONFile.read(authURL), let who = CodexAccounts.identity(of: auth) else {
            return ["state": "failed", "message": Self.lastLine(session.output) ?? "sign-in did not complete"]
        }
        let saved = try accounts.save(auth, who)
        return ["state": "done", "account": saved.account, "alreadySaved": saved.existed]
    }

    func cancel(_ id: String) {
        guard let session = sessions[id] else { return }
        if session.process.isRunning {
            session.process.terminate()
            for _ in 0..<20 where session.process.isRunning { usleep(50_000) }
            if session.process.isRunning { kill(session.process.processIdentifier, SIGKILL) }
        }
        cleanUp(id)
    }

    private func cancelAll() { sessions.keys.forEach(cancel) }

    private func cleanUp(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: session.home)
    }

    // MARK: - Helpers

    static func loginURL(in output: String) -> String? {
        for token in output.split(whereSeparator: { $0.isWhitespace }) where token.hasPrefix("https://auth.openai.com/") {
            return String(token)
        }
        return nil
    }

    private static func lastLine(_ output: String) -> String? {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    /// The codex CLI bundled with ChatGPT.app, else one on the usual PATH locations.
    static var binaryOverride: String?   // tests only

    static func codexBinary() -> String? {
        if let binaryOverride { return binaryOverride }
        var candidates: [String] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AccountPaths.chatGPTBundleID) {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex").path)
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                       AccountPaths.home.appendingPathComponent(".local/bin/codex").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
