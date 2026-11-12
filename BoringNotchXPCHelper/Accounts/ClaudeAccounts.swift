//
//  ClaudeAccounts.swift
//  BoringNotchXPCHelper
//
//  Claude accounts: the Claude Code CLI login (Keychain "Claude Code-credentials" + the
//  `oauthAccount` block of ~/.claude.json) and, optionally, the desktop app login
//  (ClaudeDesktopLogin). Ported from ccswap (oauth.py, switcher.py, credentials.py).
//
//  Safety rules (see the plan):
//  - The live CLI credential belongs to Claude Code. When it has expired (Claude Code only
//    refreshes it while it runs), it is refreshed exactly like Claude Code does it: under Claude
//    Code's two credential locks, after re-reading the Keychain item, and the rotated token goes
//    into the Keychain item first. Saved, inactive credentials are refreshed in the store. A
//    rotated token is always written before it is used.
//  - Anything we overwrite is saved first (back into its account, or into stash/).
//  - CLI switches hold Claude Code's three locks; ~/.claude.json only gets `oauthAccount` replaced.
//  - No network while all three locks are held (a refresh holds only the two credential locks).
//  - Switching never touches conversations, session history or other settings.
//

import CryptoKit
import Foundation

final class ClaudeAccounts {
    static let keychainService = "Claude Code-credentials"
    private static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private static let profileURL = "https://api.anthropic.com/api/oauth/profile"
    private static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "boring-notch"
    private static let expiryBuffer: TimeInterval = 5 * 60

    let store = AccountStore(.claude)

    struct Identity { let uuid: String; let email: String?; let organizationUuid: String?; let organizationName: String? }

    // MARK: - Status

    func status() throws -> JSONObject {
        // A Keychain error is not "logged out": report it, so the page can say what is wrong.
        var keychainError: String?
        var login: CurrentLogin?
        do { login = try currentLogin() } catch {
            keychainError = (error as? AccountsError)?.message ?? error.localizedDescription
        }
        let live = login?.creds
        let liveIdentity = login?.who
        let desktopUuid = ClaudeDesktopLogin.currentAccountUuid()
        let accounts = try store.accounts()
        var unmanaged: JSONObject?
        if let liveIdentity, !accounts.contains(where: { $0.accountUuid == liveIdentity.uuid }) {
            unmanaged = ["email": liveIdentity.email ?? ""]
        }
        return [
            "cliLoggedIn": live != nil,
            "cliKeychainError": keychainError ?? NSNull(),
            // The CLI's login expired and could not be refreshed (refresh_dead: log in again).
            "cliRefreshError": login?.refreshError?.code ?? NSNull(),
            "cliActiveId": accounts.first { $0.accountUuid != nil && $0.accountUuid == liveIdentity?.uuid }?.id ?? NSNull(),
            "unmanagedCLI": unmanaged ?? NSNull(),
            "desktopInstalled": ClaudeDesktopLogin.isInstalled,
            "desktopRunning": AppRelauncher.isRunning(AccountPaths.claudeDesktopBundleID),
            "desktopActiveId": accounts.first { $0.accountUuid != nil && $0.accountUuid == desktopUuid }?.id ?? NSNull(),
            "desktopLoginVerified": ClaudeDesktopLogin.verifiedLoginPieces,
            "accounts": accounts.map { account -> JSONObject in
                var json = account.json
                json["hasCLI"] = FileManager.default.fileExists(atPath: store.file(account.id, "credentials.json").path)
                json["hasDesktopLogin"] = FileManager.default.fileExists(atPath: store.file(account.id, "desktop-login.json").path)
                return json
            },
        ]
    }

    // MARK: - Add current login

    /// Saves the CLI's current login. When the desktop app is signed in to the same account and is
    /// quit, its login pieces are saved too (otherwise they are captured on the next switch).
    func addCurrent() throws -> JSONObject {
        guard let login = try currentLogin() else {
            throw AccountsError("claude_cli_not_logged_in", "Claude Code CLI is not logged in. Run `claude` and log in first.")
        }
        let live = login.creds
        let who = try login.who ?? identity(of: live)
        let saved = try save(live, who: who, oauthAccount: try oauthAccountBlock(for: who))
        try store.withLock {
            if ClaudeDesktopLogin.currentAccountUuid() == who.uuid,
               !AppRelauncher.isRunning(AccountPaths.claudeDesktopBundleID),
               let pieces = try? ClaudeDesktopLogin.capture(),
               let id = saved.account["id"] as? String {
                try store.writeJSON(id, "desktop-login.json", pieces)
            }
        }
        return saved.account
    }

    /// Stores `credential` as the saved CLI login of the matching account (new or existing).
    func save(_ credential: String, who: Identity, oauthAccount: JSONObject) throws -> (account: JSONObject, existed: Bool) {
        try store.withLock {
            var accounts = try store.accounts()
            let existing = accounts.first { $0.accountUuid == who.uuid }
            var account = existing ?? SavedAccount(email: who.email ?? who.uuid)
            account.email = who.email ?? account.email
            account.accountUuid = who.uuid
            account.organizationUuid = who.organizationUuid ?? account.organizationUuid
            account.organizationName = who.organizationName ?? (oauthAccount["organizationName"] as? String) ?? account.organizationName
            account.plan = Self.plan(credential: credential, oauthAccount: oauthAccount) ?? account.plan
            try store.writeText(account.id, "credentials.json", credential)
            try store.writeJSON(account.id, "oauthAccount.json", oauthAccount)
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account } else { accounts.append(account) }
            try store.save(accounts)
            return (account.json, existing != nil)
        }
    }

    /// Subscription type from the CLI credential ("max" + tier "default_claude_max_20x" → "max_20x").
    static func plan(credential: String, oauthAccount: JSONObject) -> String? {
        let oauth = JSONFile.parse(credential)?.object("claudeAiOauth") ?? [:]
        let tier = oauth.string("rateLimitTier") ?? oauthAccount.string("organizationRateLimitTier")
        guard let type = oauth.string("subscriptionType") else { return tier }
        if let tier, let range = tier.range(of: #"_(\d+x)$"#, options: .regularExpression) {
            return type + tier[range]
        }
        return type
    }

    // MARK: - Switch

    /// Switches the CLI login (when the account has one) and/or the desktop app login.
    func switchTo(_ id: String, cli: Bool, desktop: Bool, relaunchDesktop: Bool) throws -> JSONObject {
        let target = try store.account(id)
        var result: JSONObject = ["cliSwitched": false, "desktopSwitched": false]
        if cli, FileManager.default.fileExists(atPath: store.file(id, "credentials.json").path) {
            result["cliSwitched"] = try switchCLI(to: target)
        }
        if desktop, ClaudeDesktopLogin.isInstalled {
            result["desktopSwitched"] = try switchDesktop(to: target, relaunch: relaunchDesktop)
        }
        return result
    }

    private func switchCLI(to target: SavedAccount) throws -> Bool {
        for attempt in 0..<2 {
            // Network (identity lookup) happens before any lock is taken.
            let before = try liveCredential()
            let beforeIdentity = before.flatMap { try? identity(of: $0) }
            if let beforeIdentity, beforeIdentity.uuid == target.accountUuid { return false }   // already active

            let outcome: Bool? = try store.withLock {
                try ClaudeCodeLocks.withAll {
                    let live = try liveCredential()
                    // Claude Code rotated its token between our read and the lock: start over.
                    guard live == before else { return nil }
                    guard let targetCreds = try store.readText(target.id, "credentials.json") else {
                        throw AccountsError("missing_credentials", "This account has no saved Claude Code login.")
                    }
                    let targetOAuth = try store.readJSON(target.id, "oauthAccount.json")
                    // Read ~/.claude.json first: a torn file aborts before anything is written.
                    let configText = FileManager.default.fileExists(atPath: AccountPaths.claudeGlobalConfig.path)
                        ? try String(contentsOf: AccountPaths.claudeGlobalConfig, encoding: .utf8) : nil
                    var config: JSONObject = [:]
                    if let configText {
                        guard let parsed = JSONFile.parse(configText) else {
                            throw AccountsError("bad_claude_config", "~/.claude.json could not be read; nothing was changed.")
                        }
                        config = parsed
                    }

                    // 1. Save the outgoing login (it may carry a token Claude Code rotated).
                    if let live {
                        let accounts = try store.accounts()
                        if let uuid = beforeIdentity?.uuid, let owner = accounts.first(where: { $0.accountUuid == uuid }) {
                            try store.writeText(owner.id, "credentials.json", live)
                            if let current = config.object("oauthAccount"), current.string("accountUuid") == uuid {
                                try store.writeJSON(owner.id, "oauthAccount.json", current)
                            }
                        } else {
                            try store.stash(["credentials": live, "oauthAccount": config["oauthAccount"] ?? NSNull()],
                                            reason: "displaced-claude-cli-login")
                        }
                    }

                    // 2. Activate the target; roll back on any failure.
                    do {
                        try writeLive(targetCreds)
                        if let targetOAuth {
                            config["oauthAccount"] = targetOAuth
                            try PrivateFiles.atomicWriteJSON(config, to: AccountPaths.claudeGlobalConfig, pretty: true)
                        }
                        guard try liveCredential() == targetCreds else {
                            throw AccountsError("verify_failed", "The new Claude Code login could not be verified.")
                        }
                    } catch {
                        if let live { try? writeLive(live) }
                        if let configText { try? PrivateFiles.atomicWrite(Data(configText.utf8), to: AccountPaths.claudeGlobalConfig) }
                        throw error
                    }
                    return true
                }
            }
            if let outcome { return outcome }
            if attempt == 1 { throw AccountsError("changed_during_switch", "Claude Code changed its login during the switch. Try again.") }
        }
        return false
    }

    private func switchDesktop(to target: SavedAccount, relaunch: Bool) throws -> Bool {
        let currentUuid = ClaudeDesktopLogin.currentAccountUuid()
        if currentUuid != nil, currentUuid == target.accountUuid { return false }
        let wasRunning = AppRelauncher.isRunning(AccountPaths.claudeDesktopBundleID)
        guard AppRelauncher.quit(AccountPaths.claudeDesktopBundleID) else {
            throw AccountsError("desktop_still_running", "Claude did not quit, so its login was not changed.")
        }
        try store.withLock {
            let outgoing = try ClaudeDesktopLogin.capture()
            let accounts = try store.accounts()
            if let uuid = currentUuid, let owner = accounts.first(where: { $0.accountUuid == uuid }) {
                try store.writeJSON(owner.id, "desktop-login.json", outgoing)
            } else if !((outgoing["cookieDatabases"] as? [JSONObject])?.allSatisfy { ($0["rows"] as? [Any])?.isEmpty ?? true } ?? true) {
                try store.stash(["desktopLogin": outgoing, "accountUuid": currentUuid ?? NSNull()], reason: "displaced-claude-desktop-login")
            }
            let incoming = try store.readJSON(target.id, "desktop-login.json")
            do {
                try ClaudeDesktopLogin.restore(incoming)
            } catch {
                try? ClaudeDesktopLogin.restore(outgoing)
                throw error
            }
        }
        if relaunch || wasRunning { AppRelauncher.launch(AccountPaths.claudeDesktopBundleID) }
        return true
    }

    // MARK: - Manage

    func remove(_ id: String) throws {
        try store.withLock {
            try store.save(try store.accounts().filter { $0.id != id })
            try store.removeAccountFiles(id)
        }
    }

    func update(_ id: String, alias: String?, disabled: Bool?) throws {
        try store.withLock {
            try store.update(id) { account in
                if let alias { account.alias = alias.isEmpty ? nil : alias }
                if let disabled { account.disabled = disabled }
            }
        }
    }

    func move(_ id: String, to index: Int) throws {
        try store.withLock {
            var accounts = try store.accounts()
            guard let from = accounts.firstIndex(where: { $0.id == id }) else { return }
            let account = accounts.remove(at: from)
            accounts.insert(account, at: max(0, min(index, accounts.count)))
            try store.save(accounts)
        }
    }

    // MARK: - Usage

    /// Quota for one account. Uses the live credential read-only when the account is the active
    /// CLI login; refreshes only saved inactive credentials.
    func usage(_ id: String) throws -> JSONObject {
        let account = try store.account(id)
        guard let saved = try store.readText(id, "credentials.json") else {
            return ["error": "no_cli_login"]
        }
        let login = try? currentLogin()
        let live = login?.creds
        var isActive = login?.who != nil && login?.who?.uuid == account.accountUuid
        // Same refresh token as the CLI's login: it is that login, even if it couldn't be identified.
        // Refreshing it as a saved copy would revoke the CLI's token.
        if !isActive, let liveRefresh = live.flatMap(Self.oauth)?.string("refreshToken"),
           liveRefresh == Self.oauth(saved)?.string("refreshToken") {
            isActive = true
        }

        if isActive, let live {
            if let error = login?.refreshError { return ["error": error.code, "message": error.message, "active": true] }
            if Self.isExpired(live) { return ["error": "token_expired", "active": true] }
            guard let token = Self.oauth(live)?.string("accessToken") else { return ["error": "no_cli_login"] }
            return fetchUsage(token: token, active: true)
        }

        var creds = saved
        if Self.isExpired(creds) {
            switch refreshSaved(id, creds) {
            case .success(let refreshed): creds = refreshed
            case .failure(let error): return ["error": error.code, "message": error.message]
            }
        }
        guard let token = Self.oauth(creds)?.string("accessToken") else { return ["error": "no_cli_login"] }
        let first = fetchUsage(token: token, active: false)
        if (first["status"] as? Int) == 401, case .success(let refreshed) = refreshSaved(id, creds),
           let retryToken = Self.oauth(refreshed)?.string("accessToken") {
            return fetchUsage(token: retryToken, active: false)
        }
        return first
    }

    private func fetchUsage(token: String, active: Bool) -> JSONObject {
        do {
            let response = try HTTP.send(Self.usageURL, headers: [
                "Authorization": "Bearer \(token)", "anthropic-beta": Self.betaHeader, "User-Agent": Self.userAgent,
            ], timeout: 8)
            guard response.status == 200, let json = response.json else {
                var out: JSONObject = ["error": "http_\(response.status)", "status": response.status, "active": active]
                if let retry = response.retryAfter { out["retryAfter"] = retry }
                return out
            }
            return ["usage": Self.normalizeUsage(json), "active": active]
        } catch let error as AccountsError {
            return ["error": error.code, "active": active]
        } catch {
            return ["error": "network", "active": active]
        }
    }

    /// Mirrors ccswap `build_usage_result`.
    static func normalizeUsage(_ data: JSONObject) -> JSONObject {
        var windows: [JSONObject] = []
        for key in ["five_hour", "seven_day"] {
            if let window = data.object(key), let pct = window.number("utilization") {
                var entry: JSONObject = ["key": key, "pct": pct]
                if let resets = window.string("resets_at") { entry["resetsAt"] = resets }
                windows.append(entry)
            }
        }
        var models: [JSONObject] = []
        for limit in (data["limits"] as? [JSONObject]) ?? [] {
            guard let name = limit.object("scope")?.object("model")?.string("display_name"),
                  let pct = limit.number("percent") else { continue }
            var entry: JSONObject = ["name": name, "pct": pct]
            if let resets = limit.string("resets_at") { entry["resetsAt"] = resets }
            models.append(entry)
        }
        var out: JSONObject = ["windows": windows, "models": models, "fetchedAt": ISODate.string(Date())]
        if let extra = data.object("extra_usage"), extra["is_enabled"] as? Bool == true,
           let used = extra.number("used_credits"), let limit = extra.number("monthly_limit"), let pct = extra.number("utilization") {
            var spend: JSONObject = ["used": used / 100, "limit": limit / 100, "pct": pct, "currency": extra.string("currency") ?? "USD"]
            if let resets = extra.string("resets_at") { spend["resetsAt"] = resets }
            out["spend"] = spend
        }
        return out
    }

    // MARK: - Five-hour window warming (optional, off by default in the app)

    private static let warmupGuard: TimeInterval = 5 * 3600 + 60

    /// Sends one tiny Haiku prompt so an idle account's five-hour window starts now (ccswap
    /// warmup.py). Uses real subscription quota. Runs in a throw-away profile with only the access
    /// token (the refresh token is never copied or spent), and refuses to run twice for the same
    /// account within five hours (guard persisted in warmup.json, kept even if the request fails).
    func warmup(_ id: String) throws -> JSONObject {
        let account = try store.account(id)
        guard let uuid = account.accountUuid else { return ["warmed": false, "reason": "unidentified"] }
        guard let binary = Self.claudeBinary() else { return ["warmed": false, "reason": "claude_cli_missing"] }
        let live = (try? liveCredential()) ?? nil
        let isActive = live.flatMap { try? identity(of: $0) }?.uuid == uuid
        guard let creds = isActive ? live : try store.readText(id, "credentials.json"),
              !Self.isExpired(creds), let token = Self.oauth(creds)?.string("accessToken") else {
            return ["warmed": false, "reason": "token_unavailable"]   // never refresh just to warm
        }
        let guardFile = AccountPaths.store.appendingPathComponent("claude/warmup.json")
        var guards: JSONObject = (try? JSONFile.read(guardFile)) ?? [:]
        if let last = ISODate.parse(guards[uuid]), Date().timeIntervalSince(last) < Self.warmupGuard {
            return ["warmed": false, "reason": "recently_warmed"]
        }
        guards[uuid] = ISODate.string(Date())
        try PrivateFiles.atomicWriteJSON(guards, to: guardFile)   // recorded before launching

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bn-warmup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = ProcessInfo.processInfo.environment.filter { ["PATH", "LANG", "LC_ALL", "TERM"].contains($0.key) }
        env.merge(["HOME": dir.path, "TMPDIR": dir.path, "CLAUDE_CONFIG_DIR": dir.appendingPathComponent(".claude").path,
                   "CLAUDE_CODE_OAUTH_TOKEN": token, "DISABLE_AUTOUPDATER": "1",
                   "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]) { $1 }
        let result = try Subprocess.run(binary, [
            "-p", "--model", "haiku", "--max-turns", "1", "--tools", "", "--setting-sources", "",
            "--settings", #"{"disableAllHooks":true,"disableClaudeAiConnectors":true}"#,
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--disable-slash-commands", "--no-session-persistence", "--output-format", "json",
        ], stdin: Data("Reply OK.".utf8), environment: env, currentDirectory: dir, timeout: 60)
        // Raw CLI output is never returned: it may contain auth diagnostics.
        let output = JSONFile.parse(result.stdout)
        let ok = result.status == 0 && output?.string("type") == "result" && output?["is_error"] as? Bool == false
        return ["warmed": ok]
    }

    /// The `claude` CLI, if installed in one of its usual places.
    static func claudeBinary() -> String? {
        let home = AccountPaths.home.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Tokens

    private enum Refresh { case success(String), failure(AccountsError) }

    /// Refreshes a *saved, inactive* credential and persists the rotation before returning it.
    private func refreshSaved(_ id: String, _ creds: String) -> Refresh {
        do {
            let updated = try requestRefresh(creds)
            try store.withLock { try store.writeText(id, "credentials.json", updated) }   // persist before use
            return .success(updated)
        } catch let error as AccountsError {
            return .failure(error)
        } catch {
            return .failure(AccountsError("refresh_failed", "\(error)"))
        }
    }

    struct CurrentLogin { let creds: String; let who: Identity?; let refreshError: AccountsError? }

    private var liveRefreshFailure: (at: Date, error: AccountsError)?
    private static let liveRefreshRetry: TimeInterval = 10 * 60

    /// The CLI's login and whose it is (nil: not logged in; throws on Keychain errors). Claude
    /// Code only refreshes its token while it runs, and an expired token can't be identified
    /// online, so an expired login is refreshed first, exactly as Claude Code would on its next
    /// run (see refreshLive). After a failed refresh, the next try waits 10 minutes.
    func currentLogin() throws -> CurrentLogin? {
        guard var live = try liveCredential() else { return nil }
        var refreshError: AccountsError?
        var refreshed = false
        if Self.isExpired(live) {
            if let failure = liveRefreshFailure, Date().timeIntervalSince(failure.at) < Self.liveRefreshRetry {
                refreshError = failure.error
            } else {
                do {
                    let result = try refreshLive()
                    if result.creds != live { live = result.creds; refreshed = true }
                    if let error = result.keychainError { throw error }
                    liveRefreshFailure = nil
                } catch {
                    let failure = error as? AccountsError ?? AccountsError("refresh_failed", "\(error)")
                    liveRefreshFailure = (Date(), failure)
                    refreshError = failure
                }
            }
        }
        let who = try? identity(of: live)
        // Keep the rotated token in the owner's saved copy as well (it is what a switch backs up).
        if refreshed, let who, let owner = try? store.accounts().first(where: { $0.accountUuid == who.uuid }) {
            try? store.withLock { try store.writeText(owner.id, "credentials.json", live) }
        }
        return CurrentLogin(creds: live, who: who, refreshError: refreshError)
    }

    /// Refreshes the CLI's own login the way Claude Code does: under its two credential locks,
    /// re-read the Keychain item (a running Claude Code may have refreshed it meanwhile), refresh,
    /// and write the rotated tokens back to the Keychain item. Claude Code re-reads the item under
    /// the same locks before it refreshes, so it picks the new token up. If the Keychain write
    /// fails, the new tokens are stashed (the old refresh token is already revoked) and returned
    /// with the error.
    private func refreshLive() throws -> (creds: String, keychainError: AccountsError?) {
        try ClaudeCodeLocks.withCredentials {
            guard let live = try liveCredential() else {
                throw AccountsError("no_cli_login", "Claude Code is not logged in.")
            }
            guard Self.isExpired(live) else { return (live, nil) }   // refreshed by Claude Code meanwhile
            let updated = try requestRefresh(live)
            do {
                try writeLive(updated)
                return (updated, nil)
            } catch {
                try? store.stash(["credentials": updated], reason: "claude-refresh-keychain-write-failed")
                return (updated, error as? AccountsError ?? AccountsError("keychain", "\(error)"))
            }
        }
    }

    /// POSTs the refresh and returns the credential JSON with the new tokens (other fields kept).
    private func requestRefresh(_ creds: String) throws -> String {
        guard var data = JSONFile.parse(creds), var oauth = data.object("claudeAiOauth"),
              let refreshToken = oauth.string("refreshToken") else {
            throw AccountsError("no_refresh_token", "no refresh token")
        }
        let response = try HTTP.send(Self.tokenURL, method: "POST", headers: ["User-Agent": Self.userAgent],
                                     json: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID])
        guard response.status == 200, let json = response.json, let access = json.string("access_token") else {
            let code = (response.status == 400 || response.status == 401) ? "refresh_dead" : "refresh_http_\(response.status)"
            throw AccountsError(code, "token refresh failed (\(response.status))")
        }
        oauth["accessToken"] = access
        if let expiresIn = json.number("expires_in") { oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + expiresIn) * 1000) }
        if let rotated = json.string("refresh_token") { oauth["refreshToken"] = rotated }
        if let scope = json.string("scope") { oauth["scopes"] = scope.split(separator: " ").map(String.init) }
        data["claudeAiOauth"] = oauth
        return try JSONFile.string(data)
    }

    static func oauth(_ creds: String) -> JSONObject? { JSONFile.parse(creds)?.object("claudeAiOauth") }

    static func isExpired(_ creds: String) -> Bool {
        guard let expiresAt = oauth(creds)?.number("expiresAt") else { return false }
        return Date().timeIntervalSince1970 * 1000 + expiryBuffer * 1000 >= expiresAt
    }

    /// Tests only: stand-ins for Claude Code's Keychain item.
    var keychainOverride: (read: () throws -> String?, write: (String) throws -> Void)?

    func liveCredential() throws -> String? {
        if let keychainOverride { return try keychainOverride.read() }
        return try SecurityCLI.read(service: Self.keychainService)
    }

    private func writeLive(_ secret: String) throws {
        if let keychainOverride { return try keychainOverride.write(secret) }
        try SecurityCLI.write(service: Self.keychainService, secret: secret)
    }

    // MARK: - Identity

    private var identityCache: [String: Identity] = [:]
    var identityOverride: ((String) -> Identity?)?   // tests only

    /// Whose token is this? Cached per access-token hash, so the profile endpoint is only asked
    /// when the token changes. Falls back to matching saved credentials when the token is dead.
    func identity(of creds: String) throws -> Identity {
        guard let oauth = Self.oauth(creds), let token = oauth.string("accessToken") else {
            throw AccountsError("bad_credentials", "credential has no access token")
        }
        if let identityOverride, let who = identityOverride(creds) { return who }
        let key = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = identityCache[key] { return cached }

        if let response = try? HTTP.send(Self.profileURL, headers: ["Authorization": "Bearer \(token)", "User-Agent": Self.userAgent], timeout: 5),
           response.status == 200, let json = response.json,
           let uuid = json.object("account")?.string("uuid") {
            let identity = Identity(uuid: uuid, email: json.object("account")?.string("email"),
                                    organizationUuid: json.object("organization")?.string("uuid"),
                                    organizationName: json.object("organization")?.string("name"))
            identityCache[key] = identity
            return identity
        }
        // Offline or expired: the same refresh token as a saved login means the same account.
        let refresh = oauth.string("refreshToken")
        for account in try store.accounts() {
            guard let uuid = account.accountUuid,
                  let saved = try? store.readText(account.id, "credentials.json"),
                  let savedOAuth = Self.oauth(saved) else { continue }
            if savedOAuth.string("accessToken") == token || (refresh != nil && savedOAuth.string("refreshToken") == refresh) {
                return Identity(uuid: uuid, email: account.email, organizationUuid: account.organizationUuid, organizationName: account.organizationName)
            }
        }
        throw AccountsError("identity_unknown", "Could not tell which account the Claude Code login belongs to.")
    }

    /// The `oauthAccount` block to splice into ~/.claude.json when this login is activated. Taken
    /// from ~/.claude.json when it describes the same account (it is shared with the desktop app's
    /// built-in Claude Code, so it may describe another one), otherwise built from the profile.
    func oauthAccountBlock(for who: Identity, config url: URL = AccountPaths.claudeGlobalConfig) throws -> JSONObject {
        if let config = try JSONFile.read(url),
           let block = config.object("oauthAccount"), block.string("accountUuid") == who.uuid {
            return block
        }
        var block: JSONObject = ["accountUuid": who.uuid]
        if let email = who.email { block["emailAddress"] = email }
        if let org = who.organizationUuid { block["organizationUuid"] = org }
        if let name = who.organizationName { block["organizationName"] = name }
        return block
    }
}
