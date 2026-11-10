//
//  CodexAccounts.swift
//  BoringNotchXPCHelper
//
//  Codex / ChatGPT.app accounts: the file-backed `~/.codex/auth.json`. Ported from ccswap
//  (codex.py, codex_usage.py) without its `codex run` session mode.
//
//  Safety rules:
//  - Only `auth.json` is replaced; config, sessions and history in CODEX_HOME are untouched.
//  - The outgoing login is saved first (back into its account, or into stash/), and the switch is
//    refused while the current login is unmanaged.
//  - The live login is never refreshed (Codex may be refreshing it); saved inactive ones are, and
//    the rotated token is written to disk before use.
//  - A reset card is only spent on explicit request, and the request is never retried.
//

import Foundation

final class CodexAccounts {
    private static let baseURL = "https://chatgpt.com/backend-api"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let userAgent = "boring-notch"

    let store = AccountStore(.codex)

    struct Identity { let email: String; let accountId: String?; let plan: String? }

    // MARK: - Status

    func status() throws -> JSONObject {
        let live = try? readLive()
        let liveIdentity = (live ?? nil).flatMap(Self.identity(of:))
        let accounts = try store.accounts()
        let active = accounts.first { matches($0, liveIdentity) }
        var unmanaged: JSONObject?
        if let liveIdentity, active == nil { unmanaged = ["email": liveIdentity.email] }
        return [
            "fileStore": usesFileStore(),
            "loggedIn": (live ?? nil) != nil,
            "activeId": active?.id ?? NSNull(),
            "unmanaged": unmanaged ?? NSNull(),
            "appRunning": AppRelauncher.isRunning(AccountPaths.chatGPTBundleID),
            "accounts": accounts.map(\.json),
        ]
    }

    // MARK: - Add / switch

    func addCurrent() throws -> JSONObject {
        guard usesFileStore() else {
            throw AccountsError("codex_keyring_store", "Codex stores its login in the system keyring. Set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and log in again.")
        }
        guard let live = try readLive(), let who = Self.identity(of: live) else {
            throw AccountsError("codex_not_logged_in", "Codex is not logged in with a ChatGPT account.")
        }
        return try store.withLock {
            var accounts = try store.accounts()
            var account = accounts.first { matches($0, who) } ?? SavedAccount(email: who.email)
            account.email = who.email
            account.accountUuid = who.accountId
            account.plan = who.plan
            try store.writeJSON(account.id, "auth.json", live)
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account } else { accounts.append(account) }
            try store.save(accounts)
            return account.json
        }
    }

    /// Replaces auth.json with the target's saved login. Returns whether anything changed.
    /// Restarting ChatGPT.app is a separate request so the app decides (auto-switch vs manual).
    func switchTo(_ id: String) throws -> JSONObject {
        guard usesFileStore() else {
            throw AccountsError("codex_keyring_store", "Codex does not use its file credential store.")
        }
        return try store.withLock {
            let target = try store.account(id)
            guard let targetAuth = try store.readJSON(id, "auth.json") else {
                throw AccountsError("missing_credentials", "This account has no saved Codex login.")
            }
            let liveData = try? Data(contentsOf: AccountPaths.codexAuth)
            let live = liveData.flatMap(JSONFile.parse)
            let liveIdentity = live.flatMap(Self.identity(of:))
            let accounts = try store.accounts()
            if matches(target, liveIdentity) { return ["switched": false] }

            if let live {
                guard let owner = accounts.first(where: { matches($0, liveIdentity) }) else {
                    throw AccountsError("codex_unmanaged", "The current Codex login is not saved yet. Add it first so it is not lost.")
                }
                try store.writeJSON(owner.id, "auth.json", live)   // may carry a token Codex rotated
            }
            // Codex itself takes no lock we can share: re-check right before writing.
            guard (try? Data(contentsOf: AccountPaths.codexAuth)) == liveData else {
                throw AccountsError("changed_during_switch", "Codex changed its login during the switch. Try again.")
            }
            try PrivateFiles.atomicWriteJSON(targetAuth, to: AccountPaths.codexAuth, pretty: true)
            return ["switched": true, "codexCLIRunning": AppRelauncher.codexCLIRunning(),
                    "appRunning": AppRelauncher.isRunning(AccountPaths.chatGPTBundleID)]
        }
    }

    func restartApp() -> JSONObject {
        let wasRunning = AppRelauncher.isRunning(AccountPaths.chatGPTBundleID)
        guard wasRunning else { return ["restarted": false] }
        guard AppRelauncher.quit(AccountPaths.chatGPTBundleID) else { return ["restarted": false, "error": "app_did_not_quit"] }
        AppRelauncher.launch(AccountPaths.chatGPTBundleID)
        return ["restarted": true]
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

    func usage(_ id: String) throws -> JSONObject {
        let account = try store.account(id)
        let live = (try? readLive()) ?? nil
        let isActive = live.map { matches(account, Self.identity(of: $0)) } ?? false
        guard var auth = isActive ? live : try store.readJSON(id, "auth.json") else { return ["error": "no_login"] }

        var response = request(auth, "/wham/usage")
        if !isActive, let status = response["status"] as? Int, status == 401 {
            switch refreshSaved(id, auth) {
            case .success(let refreshed): auth = refreshed; response = request(auth, "/wham/usage")
            case .failure(let error): return ["error": error.code, "active": isActive]
            }
        }
        guard let payload = response["json"] as? JSONObject else {
            var out = response; out.removeValue(forKey: "json"); out["active"] = isActive
            return out
        }
        var usage = Self.normalizeUsage(payload)
        if let credits = usage["resetCredits"] as? JSONObject, (credits["available"] as? Int ?? 0) > 0,
           let details = request(auth, "/wham/rate-limit-reset-credits", beta: true)["json"] as? JSONObject,
           let expiry = Self.cards(details).first?["expiresAt"] {
            var merged = credits; merged["expiresAt"] = expiry; usage["resetCredits"] = merged
        }
        return ["usage": usage, "active": isActive]
    }

    /// Spends one banked reset (the earliest-expiring card). Never retried.
    func redeemReset(_ id: String) throws -> JSONObject {
        let account = try store.account(id)
        let live = (try? readLive()) ?? nil
        let isActive = live.map { matches(account, Self.identity(of: $0)) } ?? false
        guard let auth = isActive ? live : try store.readJSON(id, "auth.json") else { return ["error": "no_login"] }
        guard let details = request(auth, "/wham/rate-limit-reset-credits", beta: true)["json"] as? JSONObject,
              let card = Self.cards(details).first, let cardId = card["id"] as? String else {
            return ["code": "no_credit"]
        }
        var headers = Self.headers(auth)
        headers["OpenAI-Beta"] = "codex-1"
        do {
            let response = try HTTP.send(Self.baseURL + "/wham/rate-limit-reset-credits/consume", method: "POST", headers: headers,
                                         json: ["redeem_request_id": UUID().uuidString, "credit_id": cardId])
            guard let json = response.json, let code = json.string("code") else { return ["code": "unknown", "status": response.status] }
            return ["code": code]
        } catch {
            return ["code": "unknown"]
        }
    }

    // MARK: - Parsing (mirrors ccswap `_convert_payload`)

    static func normalizeUsage(_ payload: JSONObject) -> JSONObject {
        var windows: [JSONObject] = []
        if let rate = payload.object("rate_limit") {
            for (raw, fallback) in [(rate.object("primary_window"), "five_hour"), (rate.object("secondary_window"), "weekly")] {
                guard let raw, let pct = raw.number("used_percent") else { continue }
                var entry: JSONObject = ["key": windowKey(raw, fallback), "pct": pct]
                if let reset = raw.number("reset_at") { entry["resetsAt"] = ISODate.string(Date(timeIntervalSince1970: reset)) }
                windows.append(entry)
            }
        }
        var out: JSONObject = ["windows": windows, "fetchedAt": ISODate.string(Date())]
        if let credits = payload.object("rate_limit_reset_credits"), let count = credits.number("available_count") ?? credits.number("availableCount") {
            var entry: JSONObject = ["available": max(0, Int(count))]
            if let earliest = cards(credits).first?["expiresAt"] { entry["expiresAt"] = earliest }
            out["resetCredits"] = entry
        }
        if let credits = payload.object("credits") {
            var entry: JSONObject = [:]
            if let balance = credits.number("balance") { entry["balance"] = balance }
            if let unlimited = credits["unlimited"] as? Bool { entry["unlimited"] = unlimited }
            if let reached = credits["overage_limit_reached"] as? Bool { entry["limitReached"] = reached }
            if !entry.isEmpty { out["credits"] = entry }
        }
        return out
    }

    /// Classifies a window by its duration, not its position (newer plans return only a weekly primary).
    private static func windowKey(_ window: JSONObject, _ fallback: String) -> String {
        if let seconds = window.number("limit_window_seconds") ?? window.number("window_seconds") {
            if seconds == 7 * 24 * 3600 { return "weekly" }
            if seconds == 5 * 3600 { return "five_hour" }
        }
        if let minutes = window.number("window_duration_mins") ?? window.number("windowDurationMins") {
            if minutes == 7 * 24 * 60 { return "weekly" }
            if minutes == 5 * 60 { return "five_hour" }
        }
        return fallback
    }

    /// Available cards, earliest expiry first.
    private static func cards(_ payload: JSONObject) -> [JSONObject] {
        let list = (payload["credits"] as? [JSONObject]) ?? []
        return list.compactMap { card -> JSONObject? in
            guard card.string("status") == "available", let id = card.string("id") else { return nil }
            var out: JSONObject = ["id": id]
            if let expiry = ISODate.parse(card["expires_at"] ?? card["expiresAt"]) { out["expiresAt"] = ISODate.string(expiry) }
            return out
        }.sorted { ($0["expiresAt"] as? String ?? "9999") < ($1["expiresAt"] as? String ?? "9999") }
    }

    // MARK: - HTTP

    private static func headers(_ auth: JSONObject) -> [String: String] {
        let tokens = auth.object("tokens") ?? [:]
        var headers = ["Authorization": "Bearer \(tokens.string("access_token") ?? "")",
                       "User-Agent": userAgent, "Accept": "application/json"]
        let authClaims = JWT.claims(tokens["id_token"]).object("https://api.openai.com/auth")
        if let accountId = tokens.string("account_id") ?? authClaims?.string("chatgpt_account_id") {
            headers["ChatGPT-Account-ID"] = accountId
        }
        if authClaims?["chatgpt_account_is_fedramp"] as? Bool == true { headers["X-OpenAI-Fedramp"] = "true" }
        return headers
    }

    private func request(_ auth: JSONObject, _ path: String, beta: Bool = false) -> JSONObject {
        var headers = Self.headers(auth)
        if beta { headers["OpenAI-Beta"] = "codex-1" }
        do {
            let response = try HTTP.send(Self.baseURL + path, headers: headers)
            guard response.status == 200, let json = response.json else {
                var out: JSONObject = ["error": "http_\(response.status)", "status": response.status]
                if let retry = response.retryAfter { out["retryAfter"] = retry }
                return out
            }
            return ["json": json]
        } catch let error as AccountsError {
            return ["error": error.code]
        } catch {
            return ["error": "network"]
        }
    }

    private enum Refresh { case success(JSONObject), failure(AccountsError) }

    /// Refreshes a saved inactive login and persists the rotation before it is used.
    private func refreshSaved(_ id: String, _ auth: JSONObject) -> Refresh {
        guard var tokens = auth.object("tokens"), let refresh = tokens.string("refresh_token") else {
            return .failure(AccountsError("no_refresh_token", "no refresh token"))
        }
        do {
            let response = try HTTP.send(Self.tokenURL, method: "POST", headers: ["User-Agent": Self.userAgent, "Accept": "application/json"],
                                         json: ["client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refresh])
            guard response.status == 200, let json = response.json, let access = json.string("access_token") else {
                let dead = [400, 401, 403].contains(response.status)
                return .failure(AccountsError(dead ? "refresh_dead" : "refresh_http_\(response.status)", "token refresh failed"))
            }
            tokens["access_token"] = access
            if let rotated = json.string("refresh_token") { tokens["refresh_token"] = rotated }
            if let idToken = json.string("id_token") { tokens["id_token"] = idToken }
            var updated = auth
            updated["tokens"] = tokens
            updated["last_refresh"] = ISODate.string(Date())
            try store.withLock { try store.writeJSON(id, "auth.json", updated) }
            return .success(updated)
        } catch let error as AccountsError {
            return .failure(error)
        } catch {
            return .failure(AccountsError("refresh_failed", "\(error)"))
        }
    }

    // MARK: - Local state

    private func readLive() throws -> JSONObject? { try JSONFile.read(AccountPaths.codexAuth) }

    /// Codex must use its file credential store (`cli_auth_credentials_store` not "keyring").
    func usesFileStore() -> Bool {
        let config = AccountPaths.codexHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return true }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("cli_auth_credentials_store") else { continue }
            return !trimmed.contains("\"keyring\"")
        }
        return true
    }

    static func identity(of auth: JSONObject) -> Identity? {
        let tokens = auth.object("tokens") ?? [:]
        let claims = JWT.claims(tokens["id_token"])
        let authClaims = claims.object("https://api.openai.com/auth")
        let email = claims.string("email") ?? claims.object("https://api.openai.com/profile")?.string("email")
        guard let email else { return nil }
        var plan = authClaims?.string("chatgpt_plan_type")
        if plan == nil { plan = JWT.claims(tokens["access_token"]).object("https://api.openai.com/auth")?.string("chatgpt_plan_type") }
        return Identity(email: email, accountId: tokens.string("account_id") ?? authClaims?.string("chatgpt_account_id"), plan: plan)
    }

    /// Same login = same email and (when known) same ChatGPT workspace.
    private func matches(_ account: SavedAccount, _ identity: Identity?) -> Bool {
        guard let identity, account.email.lowercased() == identity.email.lowercased() else { return false }
        if let a = account.accountUuid, let b = identity.accountId { return a == b }
        return true
    }
}
