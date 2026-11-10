//
//  AIAccountsManager.swift
//  boringNotch
//
//  Claude / Codex account manager (app side of the ccswap port): keeps the account list and usage
//  for one provider, paces usage requests, runs auto-switching and optional window warming.
//  All credential work happens in the XPC helper (AccountsService); this side only sends requests.
//
//  Pacing: Anthropic's usage endpoint allows roughly 28-30 requests per hour per identity for
//  third-party clients, and a burst can lock an account out for up to an hour (ccswap
//  poll_policy.py). So usage is polled on a per-account schedule, opening the notch only shows the
//  cache, and a manual refresh skips anything fetched in the last minute.
//

import AppKit
import Defaults
import Foundation

@MainActor
final class AIAccountsManager: ObservableObject {
    static let claude = AIAccountsManager(.claude)
    static let codex = AIAccountsManager(.codex)

    let provider: AIProvider

    // Account list and live login state
    @Published private(set) var accounts: [AIAccount] = []
    @Published private(set) var activeId: String?            // CLI login (Claude) / auth.json (Codex)
    @Published private(set) var desktopActiveId: String?     // Claude desktop app
    @Published private(set) var unmanagedEmail: String?      // current login that is not saved yet
    @Published private(set) var loggedIn = false
    @Published private(set) var desktopInstalled = false
    @Published private(set) var desktopLoginVerified = false
    @Published private(set) var usesFileStore = true         // Codex: file credential store in use
    @Published private(set) var appRunning = false           // Claude.app (Claude) / ChatGPT.app (Codex)
    @Published private(set) var statusLoaded = false

    // Usage
    @Published private(set) var usage: [String: AIUsageState] = [:]

    // UI feedback
    @Published private(set) var isWorking = false
    @Published private(set) var banner: String?
    @Published private(set) var lastSwitch: Date?

    private var loopTask: Task<Void, Never>?
    private var lastStatus: Date = .distantPast
    private var lastWarmupCheck: Date = .distantPast
    private var bannerTask: Task<Void, Never>?

    private init(_ provider: AIProvider) {
        self.provider = provider
        loadCache()
    }

    // MARK: - Loop

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func tick() async {
        if Date().timeIntervalSince(lastStatus) >= 60 { await refreshStatus() }
        await pollDueAccounts(limit: 2)
        await evaluateAutoSwitch()
        await maybeWarmup()
    }

    /// Fetches usage for everything not fetched in the last minute.
    func refreshAll() async {
        await refreshStatus()
        let now = Date()
        for account in accounts where now.timeIntervalSince(usage[account.id]?.lastAttempt ?? .distantPast) >= 60 {
            usage[account.id, default: AIUsageState()].nextPoll = now
        }
        await pollDueAccounts(limit: accounts.count)
    }

    // MARK: - Status

    func refreshStatus() async {
        guard let result = try? await call("status") else { return }
        lastStatus = Date()
        accounts = decode([AIAccount].self, result["accounts"]) ?? []
        switch provider {
        case .claude:
            activeId = result["cliActiveId"] as? String
            desktopActiveId = result["desktopActiveId"] as? String
            loggedIn = result["cliLoggedIn"] as? Bool ?? false
            unmanagedEmail = (result["unmanagedCLI"] as? [String: Any])?["email"] as? String
            desktopInstalled = result["desktopInstalled"] as? Bool ?? false
            desktopLoginVerified = result["desktopLoginVerified"] as? Bool ?? false
            appRunning = result["desktopRunning"] as? Bool ?? false
        case .codex:
            activeId = result["activeId"] as? String
            loggedIn = result["loggedIn"] as? Bool ?? false
            unmanagedEmail = (result["unmanaged"] as? [String: Any])?["email"] as? String
            usesFileStore = result["fileStore"] as? Bool ?? true
            appRunning = result["appRunning"] as? Bool ?? false
        }
        let ids = Set(accounts.map(\.id))
        usage = usage.filter { ids.contains($0.key) }
        statusLoaded = true
    }

    // MARK: - Usage polling

    private func pollDueAccounts(limit: Int) async {
        let now = Date()
        let due = accounts
            .filter { (usage[$0.id]?.nextPoll ?? .distantPast) <= now }
            .sorted { (usage[$0.id]?.nextPoll ?? .distantPast) < (usage[$1.id]?.nextPoll ?? .distantPast) }
            .prefix(limit)
        guard !due.isEmpty else { return }
        for account in due { await fetchUsage(account) }
        saveCache()
    }

    private func fetchUsage(_ account: AIAccount) async {
        var state = usage[account.id] ?? AIUsageState()
        state.lastAttempt = Date()
        let result: [String: Any]
        do { result = try await call("usage", ["id": account.id]) } catch {
            state.error = (error as? AIAccountsError)?.code ?? "helper"
            state.backoff = min(3600, max(120, state.backoff * 2))
            state.nextPoll = Date().addingTimeInterval(state.backoff)
            usage[account.id] = state
            return
        }
        if let raw = result["usage"], let parsed = decode(AIUsage.self, raw) {
            state.usage = parsed
            state.lastSuccess = Date()
            state.error = nil
            state.backoff = 0
            state.nextPoll = Date().addingTimeInterval(pollInterval(account, parsed))
            // A window that resets before the next poll is re-read just after it resets.
            if let reset = parsed.windows.compactMap(\.resetDate).filter({ $0 > Date() }).min(), reset < state.nextPoll {
                state.nextPoll = reset.addingTimeInterval(30)
            }
        } else {
            let code = result["error"] as? String ?? "unknown"
            state.error = code
            switch code {
            case "http_429":
                let retry = result["retryAfter"] as? Double
                state.backoff = min(3600, max(retry ?? 900, state.backoff * 2, 900))
            case "token_expired": state.backoff = 300          // Claude Code refreshes it on next use
            case "no_cli_login", "no_login", "refresh_dead", "no_refresh_token": state.backoff = 3600
            default: state.backoff = min(3600, max(120, state.backoff * 2))
            }
            state.nextPoll = Date().addingTimeInterval(state.backoff)
        }
        usage[account.id] = state
    }

    private func pollInterval(_ account: AIAccount, _ usage: AIUsage) -> TimeInterval {
        let isActive = account.id == activeId
        let exhausted = usage.windows.contains { $0.pct >= 100 }
        var interval: TimeInterval
        switch provider {
        case .claude: interval = isActive ? 180 : (exhausted ? 600 : 1200)
        case .codex: interval = isActive ? 120 : (exhausted ? 600 : 900)
        }
        if account.disabled { interval *= 2 }
        return interval
    }

    // MARK: - Actions

    func addCurrent() async {
        await perform {
            _ = try await self.call("addCurrent")
            await self.refreshStatus()
            if let id = self.activeId { self.usage[id, default: AIUsageState()].nextPoll = .distantPast }
            await self.pollDueAccounts(limit: 1)
            self.showBanner(String(localized: "Saved the current login", comment: "AI accounts banner"))
        }
    }

    /// Switches to `account`. Manual switches confirm before quitting a running app; auto-switches
    /// follow the settings without asking.
    func switchTo(_ account: AIAccount, automatic: Bool = false) async {
        await perform {
            switch self.provider {
            case .claude:
                let desktop = Defaults[.aiClaudeSwitchDesktop] && self.desktopInstalled
                let result = try await self.call("switch", [
                    "id": account.id, "cli": Defaults[.aiClaudeSwitchCLI], "desktop": desktop,
                    "relaunchDesktop": Defaults[.aiRelaunchClaude],
                ])
                let cli = result["cliSwitched"] as? Bool ?? false
                let app = result["desktopSwitched"] as? Bool ?? false
                guard cli || app else {
                    self.showBanner(String(localized: "\(account.displayName) is already in use", comment: "AI accounts banner"))
                    return
                }
                self.showBanner(automatic
                    ? String(localized: "Auto-switched Claude to \(account.displayName)", comment: "AI accounts banner")
                    : String(localized: "Switched Claude to \(account.displayName)", comment: "AI accounts banner"))
            case .codex:
                let result = try await self.call("switch", ["id": account.id])
                guard result["switched"] as? Bool == true else {
                    self.showBanner(String(localized: "\(account.displayName) is already in use", comment: "AI accounts banner"))
                    return
                }
                var message = automatic
                    ? String(localized: "Auto-switched Codex to \(account.displayName)", comment: "AI accounts banner")
                    : String(localized: "Switched Codex to \(account.displayName)", comment: "AI accounts banner")
                if result["appRunning"] as? Bool == true {
                    if Defaults[.aiRelaunchChatGPT] {
                        _ = try? await self.call("restartApp")
                        message += String(localized: " · ChatGPT restarted", comment: "AI accounts banner suffix")
                    } else {
                        message += String(localized: " · restart ChatGPT to use it", comment: "AI accounts banner suffix")
                    }
                } else if result["codexCLIRunning"] as? Bool == true {
                    message += String(localized: " · restart running codex sessions", comment: "AI accounts banner suffix")
                }
                self.showBanner(message)
            }
            self.lastSwitch = Date()
            await self.refreshStatus()
            self.usage[account.id, default: AIUsageState()].nextPoll = Date()
        }
    }

    func remove(_ account: AIAccount) async {
        await perform {
            _ = try await self.call("remove", ["id": account.id])
            self.usage.removeValue(forKey: account.id)
            await self.refreshStatus()
            self.saveCache()
        }
    }

    func setAlias(_ account: AIAccount, _ alias: String) async {
        await perform { _ = try await self.call("update", ["id": account.id, "alias": alias]); await self.refreshStatus() }
    }

    func setDisabled(_ account: AIAccount, _ disabled: Bool) async {
        await perform { _ = try await self.call("update", ["id": account.id, "disabled": disabled]); await self.refreshStatus() }
    }

    func move(_ account: AIAccount, by offset: Int) async {
        guard let index = accounts.firstIndex(of: account) else { return }
        await perform { _ = try await self.call("move", ["id": account.id, "index": index + offset]); await self.refreshStatus() }
    }

    /// Codex only. Spends one banked reset; the helper never retries the request.
    func redeemReset(_ account: AIAccount) async {
        await perform {
            let result = try await self.call("redeemReset", ["id": account.id])
            switch result["code"] as? String {
            case "reset": self.showBanner(String(localized: "Reset redeemed for \(account.displayName)", comment: "AI accounts banner"))
            case "nothing_to_reset": self.showBanner(String(localized: "Nothing to reset; the card was kept", comment: "AI accounts banner"))
            case "no_credit": self.showBanner(String(localized: "No reset card available", comment: "AI accounts banner"))
            case "already_redeemed": self.showBanner(String(localized: "That card was already redeemed", comment: "AI accounts banner"))
            default: self.showBanner(String(localized: "Reset outcome unknown; check usage before trying again", comment: "AI accounts banner"))
            }
            self.usage[account.id, default: AIUsageState()].nextPoll = Date()
            await self.pollDueAccounts(limit: 1)
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { try await work() } catch {
            showBanner((error as? AIAccountsError)?.message ?? error.localizedDescription)
        }
    }

    private func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    // MARK: - Auto-switch (ccswap autoswitch.py rules)

    struct Gate { let pct: Double; let threshold: Double }

    /// Windows that gate an account, each with its own threshold.
    func gates(_ usage: AIUsage) -> [Gate] {
        let shared = Defaults[.aiThreshold]
        let fiveHour = Defaults[.aiThreshold5h] > 0 ? Defaults[.aiThreshold5h] : shared
        let weekly = Defaults[.aiThresholdWeekly] > 0 ? Defaults[.aiThresholdWeekly] : shared
        let windows = Defaults[.aiSwitchWindows]
        var gates: [Gate] = []
        if windows != .weekly, let w = usage.fiveHour { gates.append(Gate(pct: w.pct, threshold: fiveHour)) }
        if windows != .fiveHour, let w = usage.weekly { gates.append(Gate(pct: w.pct, threshold: weekly)) }
        if provider == .claude {
            let modelThresholds = Self.parseModelThresholds(Defaults[.aiModelThresholds])
            for model in usage.models ?? [] {
                if let t = modelThresholds[model.name.lowercased()] { gates.append(Gate(pct: model.pct, threshold: t > 0 ? t : weekly)) }
            }
        }
        return gates
    }

    func isOverThreshold(_ usage: AIUsage) -> Bool { gates(usage).contains { $0.pct >= $0.threshold } }

    /// Smallest headroom across the gating windows (percentage points left).
    func headroom(_ usage: AIUsage) -> Double { gates(usage).map { 100 - $0.pct }.min() ?? 0 }

    static func parseModelThresholds(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for part in text.split(whereSeparator: { $0 == "," || $0 == "，" }) {
            let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = pieces.first, !name.isEmpty else { continue }
            out[name.lowercased()] = pieces.count > 1 ? (Double(pieces[1]) ?? 0) : 0
        }
        return out
    }

    private var autoSwitchEnabled: Bool {
        provider == .claude ? Defaults[.aiAutoSwitchClaude] : Defaults[.aiAutoSwitchCodex]
    }

    private func evaluateAutoSwitch() async {
        guard autoSwitchEnabled, !isWorking, let activeId,
              Date().timeIntervalSince(lastSwitch ?? .distantPast) >= Defaults[.aiCooldownMinutes] * 60,
              let activeState = usage[activeId], let activeUsage = activeState.usage,
              Date().timeIntervalSince(activeState.lastSuccess ?? .distantPast) < 15 * 60,
              activeState.error == nil   // stale or failing numbers: hold, don't fail over
        else { return }

        let margin = Defaults[.aiHysteresis]
        let candidates: [(AIAccount, AIUsage)] = accounts.compactMap { account in
            guard account.id != activeId, !account.disabled,
                  provider == .codex || account.hasCLI == true,
                  let state = usage[account.id], let u = state.usage, state.error == nil,
                  Date().timeIntervalSince(state.lastSuccess ?? .distantPast) < 30 * 60,
                  !isOverThreshold(u) else { return nil }
            return (account, u)
        }
        guard !candidates.isEmpty else { return }
        let activeOver = isOverThreshold(activeUsage)

        var target: AIAccount?
        switch Defaults[.aiSwitchStrategy] {
        case .best:
            if activeOver, let best = candidates.max(by: { headroom($0.1) < headroom($1.1) }),
               headroom(best.1) >= headroom(activeUsage) + margin {
                target = best.0
            }
        case .consumeFirst:
            // Use-it-or-lose-it: prefer the account whose weekly window resets soonest.
            let roomy = candidates.filter { headroom($0.1) >= margin }
            if let soonest = roomy.min(by: { ($0.1.weekly?.resetDate ?? .distantFuture) < ($1.1.weekly?.resetDate ?? .distantFuture) }) {
                let soonestReset = soonest.1.weekly?.resetDate ?? .distantFuture
                let activeReset = activeUsage.weekly?.resetDate ?? .distantFuture
                if activeOver || soonestReset < activeReset.addingTimeInterval(-3600) { target = soonest.0 }
            }
        }
        if let target { await switchTo(target, automatic: true) }
    }

    // MARK: - Five-hour window warming (Claude, off by default; uses real quota)

    private func maybeWarmup() async {
        guard provider == .claude, Defaults[.aiWarmupClaude], !isWorking,
              Date().timeIntervalSince(lastWarmupCheck) >= 60 else { return }
        lastWarmupCheck = Date()
        // An idle account: fresh reading, no running 5-hour window, weekly headroom left.
        guard let account = accounts.first(where: { account in
            guard !account.disabled, account.hasCLI == true, let state = usage[account.id], let u = state.usage,
                  state.error == nil, Date().timeIntervalSince(state.lastSuccess ?? .distantPast) < 10 * 60 else { return false }
            let windowRunning = (u.fiveHour?.resetDate ?? .distantPast) > Date()
            return !windowRunning && (u.weekly?.pct ?? 0) < 95
        }) else { return }
        if let result = try? await call("warmup", ["id": account.id]), result["warmed"] as? Bool == true {
            usage[account.id, default: AIUsageState()].nextPoll = Date().addingTimeInterval(60)
        }
    }

    // MARK: - Helper calls

    private func call(_ op: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        var request = args
        request["provider"] = provider.rawValue
        request["op"] = op
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              let data = await XPCHelperClient.shared.accountsRequest(body),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AIAccountsError(code: "helper", message: String(localized: "The helper process is not responding.", comment: "AI accounts error"))
        }
        guard reply["ok"] as? Bool == true else {
            let code = reply["code"] as? String ?? "unknown"
            throw AIAccountsError(code: code, message: AIAccountsError.localizedMessage(code: code, fallback: reply["message"] as? String))
        }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Cache

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIAccounts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-\(provider.rawValue).json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([String: AIUsageState].self, from: data) else { return }
        // Keep the numbers but let the schedule start over (respecting any backoff still running).
        usage = cached
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(usage) { try? data.write(to: cacheURL, options: .atomic) }
    }
}

struct AIAccountsError: Error {
    let code: String
    let message: String

    /// User-facing text for the helper's error codes; falls back to the helper's own message.
    static func localizedMessage(code: String, fallback: String?) -> String {
        switch code {
        case "claude_cli_not_logged_in": return String(localized: "Claude Code CLI is not logged in. Run `claude` and log in first.")
        case "codex_not_logged_in": return String(localized: "Codex is not logged in with a ChatGPT account.")
        case "codex_keyring_store": return String(localized: "Codex keeps its login in the system keyring. Set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and log in again.")
        case "codex_unmanaged": return String(localized: "The current Codex login is not saved yet. Add it first so it is not lost.")
        case "claude_busy": return String(localized: "Claude Code is refreshing its login. Try again in a few seconds.")
        case "changed_during_switch": return String(localized: "The login changed during the switch. Try again.")
        case "desktop_still_running": return String(localized: "Claude did not quit, so its login was not changed.")
        case "missing_credentials": return String(localized: "This account has no saved login for that app.")
        case "identity_unknown": return String(localized: "Could not tell which account the current login belongs to.")
        case "bad_claude_config": return String(localized: "~/.claude.json could not be read; nothing was changed.")
        case "keychain": return String(localized: "The Keychain could not be read or written.")
        default: return fallback ?? code
        }
    }
}
