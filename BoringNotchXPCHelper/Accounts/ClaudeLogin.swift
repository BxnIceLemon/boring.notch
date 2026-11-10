//
//  ClaudeLogin.swift
//  BoringNotchXPCHelper
//
//  Adds a Claude account without touching the current CLI login: `claude auth login` runs with a
//  private temporary CLAUDE_CONFIG_DIR. Claude Code then keeps that login in its own Keychain item
//  ("Claude Code-credentials-<first 8 hex of sha256(config dir)>") and its own .claude.json, so the
//  real "Claude Code-credentials" item and ~/.claude.json are never read or written. The fresh
//  login is copied into the account store, then the temporary item and directory are deleted.
//
//  The sign-in link: BROWSER points at a tiny script that hands us the URL Claude Code would open
//  (it redirects back to Claude Code's local listener, so the sign-in completes by itself, also
//  from a private window). If that never shows up, the printed manual link is used instead and
//  the user pastes the code the page shows.
//

import CryptoKit
import Foundation

final class ClaudeLogin {
    private var sessions: [String: LoginProcess] = [:]
    private let accounts: ClaudeAccounts
    private let readSecret: (String) throws -> String?
    private let deleteSecret: (String) throws -> Void

    init(accounts: ClaudeAccounts,
         readSecret: @escaping (String) throws -> String? = { try SecurityCLI.read(service: $0) },
         deleteSecret: @escaping (String) throws -> Void = { try SecurityCLI.delete(service: $0) }) {
        self.accounts = accounts
        self.readSecret = readSecret
        self.deleteSecret = deleteSecret
    }

    static var binaryOverride: String?   // tests only

    private var loginRoot: URL { AccountPaths.store.appendingPathComponent("claude-login", isDirectory: true) }

    /// Claude Code's Keychain service for a custom config directory (its kW()).
    static func keychainService(forConfigDir dir: URL) -> String {
        let path = dir.path.precomposedStringWithCanonicalMapping   // NFC, like Claude Code
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return "\(ClaudeAccounts.keychainService)-\(hash)"
    }

    // MARK: - Start

    func start() throws -> JSONObject {
        sessions.keys.forEach(cancel)
        // A crashed earlier run may have left its directory, and with it a temporary Keychain item.
        for dir in (try? FileManager.default.contentsOfDirectory(at: loginRoot, includingPropertiesForKeys: nil)) ?? [] {
            let service = Self.keychainService(forConfigDir: dir)
            if service != ClaudeAccounts.keychainService { try? deleteSecret(service) }
        }
        guard let claude = Self.binaryOverride ?? ClaudeAccounts.claudeBinary() else {
            throw AccountsError("claude_cli_missing", "Install the Claude Code CLI first.")
        }
        let session = try LoginProcess(
            root: loginRoot, executable: claude, arguments: ["auth", "login", "--claudeai"],
            environment: { home in
                ["CLAUDE_CONFIG_DIR": home.path, "BROWSER": home.appendingPathComponent("open-url.sh").path]
            },
            // Each of these would point the CLI at the real login (or skip the sign-in entirely).
            unset: ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
            prepare: { home in
                let script = "#!/bin/sh\nprintf '%s' \"$1\" > \"$(dirname \"$0\")/open-url.txt\"\n"
                let url = home.appendingPathComponent("open-url.sh")
                try PrivateFiles.atomicWrite(Data(script.utf8), to: url, permissions: 0o700)
            })
        guard Self.keychainService(forConfigDir: session.home) != ClaudeAccounts.keychainService else {
            session.finish()
            throw AccountsError("internal", "refusing to sign in against the real Keychain item")
        }
        sessions[session.id] = session

        let opened = session.home.appendingPathComponent("open-url.txt")
        func automatic() -> String? {
            (try? String(contentsOf: opened, encoding: .utf8)).flatMap { $0.hasPrefix("https://") ? $0 : nil }
        }
        func manual() -> String? {
            LoginProcess.firstURL(in: session.output, prefix: "https://claude.com/")
                ?? LoginProcess.firstURL(in: session.output, prefix: "https://claude.ai/")
        }
        _ = session.wait(seconds: 20) { automatic() ?? manual() }
        if automatic() == nil, manual() != nil { _ = session.wait(seconds: 2, for: automatic) }
        if let url = automatic() { return ["loginId": session.id, "url": url, "needsCode": false] }
        if let url = manual() { return ["loginId": session.id, "url": url, "needsCode": true] }
        let last = session.lastLine
        cancel(session.id)
        throw AccountsError("claude_login_failed", last ?? "claude auth login did not start")
    }

    // MARK: - Poll / code / cancel

    func poll(_ id: String) throws -> JSONObject {
        guard let session = sessions[id] else { return ["state": "failed", "message": "sign-in was cancelled"] }
        if session.isRunning {
            guard !session.timedOut else { cancel(id); return ["state": "failed", "code": "login_timeout"] }
            return ["state": "pending"]
        }
        defer { cancel(id) }
        let service = Self.keychainService(forConfigDir: session.home)
        let fileFallback = session.home.appendingPathComponent(".credentials.json")
        guard let credential = try readSecret(service) ?? (try? String(contentsOf: fileFallback, encoding: .utf8)),
              ClaudeAccounts.oauth(credential)?.string("accessToken") != nil else {
            return ["state": "failed", "message": session.lastLine ?? "sign-in did not complete"]
        }
        let who = try accounts.identity(of: credential)
        let block = try accounts.oauthAccountBlock(for: who, config: session.home.appendingPathComponent(".claude.json"))
        let saved = try accounts.save(credential, who: who, oauthAccount: block)
        return ["state": "done", "account": saved.account, "alreadySaved": saved.existed]
    }

    /// The code shown by the manual sign-in page.
    func submitCode(_ id: String, _ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        sessions[id]?.send(trimmed)
    }

    /// Stops the sign-in and removes everything it created: the temporary Keychain item too.
    func cancel(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        let service = Self.keychainService(forConfigDir: session.home)
        session.finish()
        if service != ClaudeAccounts.keychainService { try? deleteSecret(service) }
    }
}
