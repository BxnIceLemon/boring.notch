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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(manager.accounts) { account in
                        AIAccountCard(manager: manager, account: account)
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

// MARK: - Account card

struct AIAccountCard: View {
    @ObservedObject var manager: AIAccountsManager
    let account: AIAccount
    @State private var hovering = false

    private var state: AIUsageState? { manager.usage[account.id] }
    private var isActive: Bool { account.id == manager.activeId }
    private var isDesktopActive: Bool { manager.provider == .claude && account.id == manager.desktopActiveId }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if let subtitle = account.subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.gray).lineLimit(1)
            }
            if let usage = state?.usage {
                ForEach(usage.windows, id: \.key) { window in
                    AIUsageRow(label: label(for: window.key), pct: window.pct, reset: window.resetDate)
                }
                ForEach((usage.models ?? []).prefix(2), id: \.name) { model in
                    AIUsageRow(label: model.name, pct: model.pct, reset: model.resetDate)
                }
                if let credits = usage.resetCredits, credits.available > 0 {
                    Text(resetCreditsText(credits)).font(.caption2).foregroundStyle(.gray).lineLimit(1)
                }
            } else if state?.error == nil {
                Text("Waiting for the first reading…").font(.caption2).foregroundStyle(.gray)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(8)
        .frame(width: 196, height: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(hovering ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.effectiveAccent.opacity(0.8) : .clear, lineWidth: 1)
        )
        .opacity(account.disabled ? 0.55 : 1)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(account.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if isActive { AITag(text: manager.provider == .claude ? "CLI" : String(localized: "Active"), color: .green) }
            if isDesktopActive { AITag(text: "App", color: .green) }
            if account.disabled { AITag(text: String(localized: "Disabled"), color: .gray) }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Group {
                if let error = state?.error {
                    Text(AIAccountCard.errorText(error)).foregroundStyle(.orange)
                } else if let date = state?.lastSuccess {
                    Text("Updated \(AIDates.countdown(to: Date(), now: date)) ago").foregroundStyle(.gray)
                }
            }
            .font(.caption2)
            .lineLimit(1)
            Spacer(minLength: 2)
            if !isActive || (manager.provider == .claude && !isDesktopActive && manager.desktopInstalled) {
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
    }

    @ViewBuilder
    private var menu: some View {
        Button("Switch to This Account") { Task { await AIAccountActions.switchTo(account, manager: manager) } }
        Button(account.disabled ? "Include in Auto-switch" : "Exclude from Auto-switch") {
            Task { await manager.setDisabled(account, !account.disabled) }
        }
        Button("Rename…") { AIAccountActions.rename(account, manager: manager) }
        Divider()
        Button("Move Left") { Task { await manager.move(account, by: -1) } }
            .disabled(manager.accounts.first == account)
        Button("Move Right") { Task { await manager.move(account, by: 1) } }
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

    static func errorText(_ code: String) -> String {
        switch code {
        case "token_expired": return String(localized: "Token expired; waiting for the CLI to refresh it")
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
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.gray)
                .frame(width: 30, alignment: .leading)
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
                .frame(width: 32, alignment: .trailing)
            if let reset, reset > Date() {
                Text(AIDates.countdown(to: reset))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.gray)
                    .frame(width: 44, alignment: .trailing)
                    .lineLimit(1)
            }
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
