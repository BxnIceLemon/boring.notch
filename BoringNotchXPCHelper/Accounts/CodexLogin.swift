//
//  CodexLogin.swift
//  BoringNotchXPCHelper
//
//  Adds a Codex account without touching the current login: ChatGPT's own `codex login` runs
//  against a private temporary CODEX_HOME, the fresh login is saved into the account store, and
//  the directory is deleted. ~/.codex is never read or written by this flow.
//

import AppKit
import Foundation

final class CodexLogin {
    private var sessions: [String: LoginProcess] = [:]
    private let accounts: CodexAccounts

    init(accounts: CodexAccounts) { self.accounts = accounts }

    private var loginRoot: URL { AccountPaths.store.appendingPathComponent("codex-login", isDirectory: true) }

    /// Starts the sign-in and returns its URL. The browser is not opened here: the app shows the
    /// link so it can also be pasted into a private window.
    func start() throws -> JSONObject {
        sessions.keys.forEach(cancel)
        guard let codex = Self.codexBinary() else {
            throw AccountsError("codex_cli_missing", "Could not find the codex command that comes with ChatGPT.")
        }
        let session = try LoginProcess(
            root: loginRoot, executable: codex, arguments: ["login"],
            environment: { ["CODEX_HOME": $0.path, "BROWSER": "/usr/bin/true"] },
            prepare: { home in
                // File store, so the login lands in home/auth.json instead of the Keychain.
                try PrivateFiles.atomicWrite(Data("cli_auth_credentials_store = \"file\"\n".utf8),
                                             to: home.appendingPathComponent("config.toml"))
            })
        sessions[session.id] = session
        if let url = session.wait(seconds: 20, for: { LoginProcess.firstURL(in: session.output, prefix: "https://auth.openai.com/") }) {
            return ["loginId": session.id, "url": url]
        }
        let output = session.output
        cancel(session.id)
        if output.localizedCaseInsensitiveContains("address already in use") || output.localizedCaseInsensitiveContains("address in use") {
            throw AccountsError("codex_login_port_busy", "Another sign-in is already waiting on port 1455.")
        }
        throw AccountsError("codex_login_failed", output.split(separator: "\n").last.map(String.init) ?? "codex login did not start")
    }

    /// {"state": "pending"} while the browser sign-in is open; {"state": "done", "account": …,
    /// "alreadySaved": Bool} once it finished and was saved; {"state": "failed", …}.
    func poll(_ id: String) throws -> JSONObject {
        guard let session = sessions[id] else { return ["state": "failed", "message": "sign-in was cancelled"] }
        if session.isRunning {
            guard !session.timedOut else { cancel(id); return ["state": "failed", "code": "codex_login_timeout"] }
            return ["state": "pending"]
        }
        defer { cancel(id) }
        guard let auth = try JSONFile.read(session.home.appendingPathComponent("auth.json")),
              let who = CodexAccounts.identity(of: auth) else {
            return ["state": "failed", "message": session.lastLine ?? "sign-in did not complete"]
        }
        let saved = try accounts.save(auth, who)
        return ["state": "done", "account": saved.account, "alreadySaved": saved.existed]
    }

    func cancel(_ id: String) {
        sessions.removeValue(forKey: id)?.finish()
    }

    static var binaryOverride: String?   // tests only

    /// The codex CLI bundled with ChatGPT.app, else one on the usual PATH locations.
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
