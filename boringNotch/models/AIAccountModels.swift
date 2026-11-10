//
//  AIAccountModels.swift
//  boringNotch
//
//  App-side models for the Claude / Codex account pages. They mirror the JSON the XPC helper's
//  AccountsService returns; credentials never reach the app, only metadata and usage.
//

import Defaults
import Foundation

enum AIProvider: String, Codable, CaseIterable {
    case claude, codex
}

struct AIAccount: Codable, Identifiable, Hashable {
    let id: String
    var email: String
    var accountUuid: String?
    var organizationName: String?
    var plan: String?
    var alias: String?
    var disabled: Bool
    var hasCLI: Bool?
    var hasDesktopLogin: Bool?

    var displayName: String { alias?.isEmpty == false ? alias! : email }

    /// Subscription type as a short tag ("Plus", "Pro", "Max", "Team").
    var planLabel: String? {
        guard var plan = plan?.lowercased(), !plan.isEmpty else { return nil }
        for prefix in ["default_", "claude_"] where plan.hasPrefix(prefix) { plan.removeFirst(prefix.count) }
        // "max_20x" → "Max 20x" (capitalize words, keep multipliers as they are)
        return plan.split(separator: "_").map { word in
            word.first?.isLetter == true ? word.prefix(1).uppercased() + word.dropFirst() : String(word)
        }.joined(separator: " ")
    }

    /// Short plan / organization label shown under the name.
    var subtitle: String? {
        if let plan, !plan.isEmpty {
            let pretty = plan.replacingOccurrences(of: "_", with: " ")
            return organizationName.map { "\($0) · \(pretty)" } ?? pretty.capitalized
        }
        return organizationName
    }
}

struct AIUsageWindow: Codable, Hashable {
    /// "five_hour", "seven_day" (Claude) or "weekly" (Codex).
    let key: String
    let pct: Double
    let resetsAt: String?

    var resetDate: Date? { AIDates.parse(resetsAt) }
    var isWeekly: Bool { key == "seven_day" || key == "weekly" }
}

struct AIModelWindow: Codable, Hashable {
    let name: String
    let pct: Double
    let resetsAt: String?
    var resetDate: Date? { AIDates.parse(resetsAt) }
}

struct AISpend: Codable, Hashable {
    let used: Double
    let limit: Double
    let pct: Double
    let currency: String
    let resetsAt: String?
}

struct AIResetCredits: Codable, Hashable {
    let available: Int
    let expiresAt: String?
    var expiryDate: Date? { AIDates.parse(expiresAt) }
}

struct AIUsage: Codable, Hashable {
    var windows: [AIUsageWindow]
    var models: [AIModelWindow]?
    var spend: AISpend?
    var resetCredits: AIResetCredits?
    var fetchedAt: String?

    var fiveHour: AIUsageWindow? { windows.first { $0.key == "five_hour" } }
    var weekly: AIUsageWindow? { windows.first { $0.isWeekly } }
}

/// Polling and error state for one account's usage (persisted so numbers show right after launch).
struct AIUsageState: Codable, Hashable {
    var usage: AIUsage?
    var lastSuccess: Date?
    var lastAttempt: Date?
    var nextPoll: Date = .distantPast
    var backoff: TimeInterval = 0
    /// Helper error code of the last attempt ("token_expired", "http_429", "refresh_dead", …).
    var error: String?
}

enum AIDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    /// "2h 13m", "3d 4h", "12m" until `date`.
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86400, hours = (seconds % 86400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return String(localized: "\(days)d \(hours)h", comment: "Countdown: days and hours") }
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m", comment: "Countdown: hours and minutes") }
        return String(localized: "\(max(1, minutes))m", comment: "Countdown: minutes")
    }
}

// MARK: - Settings

enum AISwitchStrategy: String, CaseIterable, Identifiable, Defaults.Serializable {
    case best
    case consumeFirst
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .best: return String(localized: "Most quota left", comment: "Auto-switch strategy")
        case .consumeFirst: return String(localized: "Soonest weekly reset first", comment: "Auto-switch strategy")
        }
    }
}

enum AISwitchWindows: String, CaseIterable, Identifiable, Defaults.Serializable {
    case both, fiveHour, weekly
    var id: String { rawValue }
    var localizedName: String {
        switch self {
        case .both: return String(localized: "5-hour and weekly", comment: "Auto-switch windows")
        case .fiveHour: return String(localized: "5-hour only", comment: "Auto-switch windows")
        case .weekly: return String(localized: "Weekly only", comment: "Auto-switch windows")
        }
    }
}

extension Defaults.Keys {
    static let aiAutoSwitchClaude = Key<Bool>("aiAutoSwitchClaude", default: false)
    static let aiAutoSwitchCodex = Key<Bool>("aiAutoSwitchCodex", default: false)
    static let aiSwitchStrategy = Key<AISwitchStrategy>("aiSwitchStrategy", default: .best)
    static let aiSwitchWindows = Key<AISwitchWindows>("aiSwitchWindows", default: .both)
    /// Shared threshold (%). The per-window ones use 0 for "inherit".
    static let aiThreshold = Key<Double>("aiThreshold", default: 90)
    static let aiThreshold5h = Key<Double>("aiThreshold5h", default: 0)
    static let aiThresholdWeekly = Key<Double>("aiThresholdWeekly", default: 0)
    /// Claude per-model weekly gates, e.g. "Fable=40, Opus=60". Each named model becomes a gate.
    static let aiModelThresholds = Key<String>("aiModelThresholds", default: "")
    static let aiCooldownMinutes = Key<Double>("aiCooldownMinutes", default: 5)
    /// A proactive switch must improve on the current account by at least this many points.
    static let aiHysteresis = Key<Double>("aiHysteresis", default: 10)
    static let aiClaudeSwitchCLI = Key<Bool>("aiClaudeSwitchCLI", default: true)
    static let aiClaudeSwitchDesktop = Key<Bool>("aiClaudeSwitchDesktop", default: true)
    static let aiRelaunchClaude = Key<Bool>("aiRelaunchClaude", default: true)
    /// When the Claude desktop app signs in to another saved account, switch the CLI to it too.
    static let aiClaudeCLIFollowsDesktop = Key<Bool>("aiClaudeCLIFollowsDesktop", default: true)
    /// The saved account the desktop app was last seen on ("" = none / not saved).
    static let aiClaudeLastDesktopId = Key<String>("aiClaudeLastDesktopId", default: "")
    static let aiRelaunchChatGPT = Key<Bool>("aiRelaunchChatGPT", default: true)
    static let aiWarmupClaude = Key<Bool>("aiWarmupClaude", default: false)
}
