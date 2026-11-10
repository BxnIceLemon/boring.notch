//
//  AssistantViews.swift
//  boringNotch
//
//  The Codex and Claude pages of the open notch: saved accounts with their quota windows,
//  one-click switching and the auto-switch toggle. Backed by AIAccountsManager.
//

import AppKit
import Defaults
import SwiftUI

struct CodexView: View {
    var body: some View { AIAccountsPage(manager: .codex) }
}

struct ClaudeView: View {
    var body: some View { AIAccountsPage(manager: .claude) }
}

struct AIAccountsPage: View {
    @ObservedObject var manager: AIAccountsManager
    @Default(.aiAutoSwitchClaude) private var autoClaude
    @Default(.aiAutoSwitchCodex) private var autoCodex

    private var autoSwitch: Binding<Bool> {
        manager.provider == .claude ? $autoClaude : $autoCodex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            manager.start()
            Task { await manager.refreshStatus() }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(manager.provider == .claude ? "Claude" : "Codex")
                .font(.headline)
                .foregroundStyle(.white)
            Group {
                if let banner = manager.banner {
                    Text(banner).foregroundStyle(.white)
                } else if let email = manager.unmanagedEmail {
                    Text("Current login \(email) is not saved").foregroundStyle(.orange)
                } else if let active = manager.accounts.first(where: { $0.id == manager.activeId }) {
                    Text("Current: \(active.displayName)").foregroundStyle(.gray)
                } else if manager.statusLoaded && !manager.loggedIn {
                    Text(manager.provider == .claude ? "Claude Code CLI not logged in" : "Codex not logged in").foregroundStyle(.gray)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 4)
            if manager.isWorking { ProgressView().controlSize(.mini) }
            Toggle(isOn: autoSwitch) { Text("Auto-switch").font(.caption).foregroundStyle(.gray) }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(manager.accounts.count < 2)
            HoverButton(icon: "arrow.clockwise", iconColor: .gray, scale: .small) {
                Task { await manager.refreshAll() }
            }
            HoverButton(icon: "plus", iconColor: .gray, scale: .small) {
                Task { await manager.addCurrent() }
            }
            .help(Text("Save the current login"))
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !manager.statusLoaded {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(maxHeight: .infinity)
        } else if manager.accounts.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(manager.accounts) { account in
                        AIAccountRow(manager: manager, account: account)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch manager.provider {
            case .claude:
                Text(manager.loggedIn
                     ? "Click + to save the Claude Code login that is active now. Log in with your next account and save it again."
                     : "Install and log in to the Claude Code CLI, then click + to save the account. Repeat for each account.")
            case .codex:
                if !manager.usesFileStore {
                    Text("Codex keeps its login in the system keyring. Set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml and log in again.")
                } else {
                    Text(manager.loggedIn
                         ? "Click + to save the Codex login that is active now. Log in with your next account and save it again."
                         : "Log in to ChatGPT (Codex), then click + to save the account.")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Account row

/// One line per account, like ccswap's pane: marker, name, a bar per quota window, Switch.
/// Details that don't fit on the line (plan, per-model limits, last update) are in the tooltip.
struct AIAccountRow: View {
    @ObservedObject var manager: AIAccountsManager
    let account: AIAccount
    @State private var hovering = false

    private var state: AIUsageState? { manager.usage[account.id] }
    private var isActive: Bool { account.id == manager.activeId }
    private var isDesktopActive: Bool { manager.provider == .claude && account.id == manager.desktopActiveId }
    private var canSwitch: Bool {
        !isActive || (manager.provider == .claude && !isDesktopActive && manager.desktopInstalled)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(isActive || isDesktopActive ? Color.green : Color.white.opacity(0.18))
                .frame(width: 6, height: 6)
            nameColumn
            windows
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(hovering ? 0.10 : (isActive ? 0.06 : 0)))
        )
        .opacity(account.disabled ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip)
        .contextMenu { menu }
    }

    /// Name on the first line, plan and where the account is in use on the second.
    private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(account.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                if let plan = account.planLabel { AITag(text: plan, color: .white.opacity(0.7)) }
                if isActive && manager.provider == .claude { AITag(text: "CLI", color: .green) }
                if isActive && manager.provider == .codex { AITag(text: String(localized: "Active"), color: .green) }
                if isDesktopActive { AITag(text: "App", color: .green) }
                if account.disabled { AITag(text: String(localized: "Disabled"), color: .gray) }
            }
        }
        .frame(width: 150, alignment: .leading)
    }

    @ViewBuilder
    private var windows: some View {
        if let usage = state?.usage, !usage.windows.isEmpty {
            // One line per window, like ccswap: 5h above, weekly below.
            VStack(spacing: 4) {
                ForEach(usage.windows, id: \.key) { window in
                    AIUsageRow(label: label(for: window.key), pct: window.pct, reset: window.resetDate)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Group {
                if let error = state?.error {
                    Text(AIAccountRow.errorText(error, manager.provider)).foregroundStyle(.orange)
                } else {
                    Text("Waiting for the first reading…").foregroundStyle(.gray)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            if state?.usage != nil, let error = state?.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help(AIAccountRow.errorText(error, manager.provider))
            }
            if let credits = state?.usage?.resetCredits, credits.available > 0 {
                AITag(text: "↺×\(credits.available)", color: .effectiveAccent)
            }
            if canSwitch {
                Button {
                    Task { await AIAccountActions.switchTo(account, manager: manager) }
                } label: {
                    Text("Switch").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.effectiveAccent.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(manager.isWorking)
            }
        }
        .frame(width: 84, alignment: .trailing)
    }

    private var tooltip: String {
        var lines: [String] = [account.email]
        if let subtitle = account.subtitle { lines.append(subtitle) }
        for model in state?.usage?.models ?? [] {
            var line = "\(model.name): \(Int(model.pct.rounded()))%"
            if let reset = model.resetDate, reset > Date() { line += " · \(AIDates.countdown(to: reset))" }
            lines.append(line)
        }
        if let credits = state?.usage?.resetCredits, credits.available > 0 { lines.append(resetCreditsText(credits)) }
        if let error = state?.error { lines.append(AIAccountRow.errorText(error, manager.provider)) }
        if let date = state?.lastSuccess {
            lines.append(String(localized: "Updated \(AIDates.countdown(to: Date(), now: date)) ago"))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Switch to This Account") { Task { await AIAccountActions.switchTo(account, manager: manager) } }
        Button(account.disabled ? "Include in Auto-switch" : "Exclude from Auto-switch") {
            Task { await manager.setDisabled(account, !account.disabled) }
        }
        Button("Rename…") { AIAccountActions.rename(account, manager: manager) }
        Divider()
        Button("Move Up") { Task { await manager.move(account, by: -1) } }
            .disabled(manager.accounts.first == account)
        Button("Move Down") { Task { await manager.move(account, by: 1) } }
            .disabled(manager.accounts.last == account)
        if manager.provider == .codex, (state?.usage?.resetCredits?.available ?? 0) > 0 {
            Divider()
            Button("Redeem a Reset Card…") { AIAccountActions.redeem(account, manager: manager) }
        }
        Divider()
        Button("Remove Account…", role: .destructive) { AIAccountActions.remove(account, manager: manager) }
    }

    private func label(for key: String) -> String {
        switch key {
        case "five_hour": return String(localized: "5h", comment: "Five-hour quota window label")
        case "seven_day": return String(localized: "7d", comment: "Seven-day quota window label")
        default: return String(localized: "Week", comment: "Weekly quota window label")
        }
    }

    private func resetCreditsText(_ credits: AIResetCredits) -> String {
        if let expiry = credits.expiryDate {
            return String(localized: "Reset cards ×\(credits.available) · expires in \(AIDates.countdown(to: expiry))")
        }
        return String(localized: "Reset cards ×\(credits.available)")
    }

    static func errorText(_ code: String, _ provider: AIProvider) -> String {
        switch code {
        case "token_expired":
            return provider == .codex
                ? String(localized: "Token expired; waiting for Codex to refresh it")
                : String(localized: "Token expired; waiting for the CLI to refresh it")
        case "http_429": return String(localized: "Rate limited; retrying later")
        case "refresh_dead", "no_refresh_token": return String(localized: "Login expired; log in again and re-save")
        case "no_cli_login": return String(localized: "No CLI login; quota unavailable")
        case "network", "timeout": return String(localized: "Network error")
        default: return String(localized: "Could not read quota")
        }
    }
}

struct AIUsageRow: View {
    let label: String
    let pct: Double
    let reset: Date?

    private var color: Color { pct >= 90 ? .red : pct >= 70 ? .orange : .effectiveAccent }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.gray)
                .frame(width: 22, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color).frame(width: geo.size.width * min(max(pct, 0), 100) / 100)
                }
            }
            .frame(height: 4)
            Text("\(Int(pct.rounded()))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 30, alignment: .trailing)
            // Always reserve the reset columns so bars line up from row to row.
            let upcoming = reset.flatMap { $0 > Date() ? $0 : nil }
            Text(upcoming.map { AIDates.countdown(to: $0) } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.gray)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Text(upcoming.map { $0.formatted(.dateTime.month(.defaultDigits).day().hour().minute()) } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.gray.opacity(0.7))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1)
        }
    }
}

struct AITag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.25)))
            .foregroundStyle(color)
    }
}

// MARK: - Dialogs

/// System dialogs for actions that need confirmation or text input (the notch panel never takes
/// keyboard focus). The notch is kept open while a dialog is up.
@MainActor
enum AIAccountActions {
    static func switchTo(_ account: AIAccount, manager: AIAccountsManager) async {
        var message: String?
        switch manager.provider {
        case .claude:
            if Defaults[.aiClaudeSwitchDesktop], manager.desktopInstalled, manager.appRunning, account.id != manager.desktopActiveId {
                message = String(localized: "Claude will quit and reopen with this account. Conversations and settings stay as they are.")
            }
        case .codex:
            if manager.appRunning {
                message = Defaults[.aiRelaunchChatGPT]
                    ? String(localized: "ChatGPT will quit and reopen with this account.")
                    : String(localized: "Restart ChatGPT afterwards to use this account.")
            }
        }
        if let message, !confirm(title: String(localized: "Switch to \(account.displayName)?"), message: message,
                                 button: String(localized: "Switch")) { return }
        await manager.switchTo(account)
    }

    static func remove(_ account: AIAccount, manager: AIAccountsManager) {
        guard confirm(title: String(localized: "Remove \(account.displayName)?"),
                      message: String(localized: "Its saved login is deleted from Boring Notch. The account itself and the app you are logged in to are not affected."),
                      button: String(localized: "Remove"), destructive: true) else { return }
        Task { await manager.remove(account) }
    }

    static func redeem(_ account: AIAccount, manager: AIAccountsManager) {
        var message = String(localized: "This spends one banked reset to reset the usage limits of this account now.")
        if let expiry = manager.usage[account.id]?.usage?.resetCredits?.expiryDate {
            message += "\n" + String(localized: "The earliest card expires \(expiry.formatted(date: .abbreviated, time: .shortened)).")
        }
        guard confirm(title: String(localized: "Redeem a reset card?"), message: message,
                      button: String(localized: "Redeem")) else { return }
        Task { await manager.redeemReset(account) }
    }

    static func rename(_ account: AIAccount, manager: AIAccountsManager) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = account.alias ?? ""
        field.placeholderString = account.email
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename \(account.email)")
        alert.informativeText = String(localized: "Leave empty to show the email address.")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard run(alert) == .alertFirstButtonReturn else { return }
        let alias = field.stringValue.trimmingCharacters(in: .whitespaces)
        Task { await manager.setAlias(account, alias) }
    }

    private static func confirm(title: String, message: String, button: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return run(alert) == .alertFirstButtonReturn
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        SharingStateManager.shared.beginInteraction()
        defer { SharingStateManager.shared.endInteraction() }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}
