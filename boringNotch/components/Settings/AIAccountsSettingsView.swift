//
//  AIAccountsSettingsView.swift
//  boringNotch
//
//  Settings for the Claude / Codex account pages: auto-switch rules (ccswap autoswitch options),
//  what a Claude switch changes, app restarts and optional five-hour window warming.
//

import Defaults
import SwiftUI

struct AIAccountsSettings: View {
    @Default(.aiAutoSwitchClaude) private var autoClaude
    @Default(.aiAutoSwitchCodex) private var autoCodex
    @Default(.aiSwitchStrategy) private var strategy
    @Default(.aiSwitchWindows) private var windows
    @Default(.aiThreshold) private var threshold
    @Default(.aiThreshold5h) private var threshold5h
    @Default(.aiThresholdWeekly) private var thresholdWeekly
    @Default(.aiModelThresholds) private var modelThresholds
    @Default(.aiCooldownMinutes) private var cooldown
    @Default(.aiHysteresis) private var hysteresis
    @Default(.aiClaudeSwitchCLI) private var switchCLI
    @Default(.aiClaudeSwitchDesktop) private var switchDesktop
    @Default(.aiRelaunchClaude) private var relaunchClaude
    @Default(.aiClaudeCLIFollowsDesktop) private var cliFollowsDesktop
    @Default(.aiRelaunchChatGPT) private var relaunchChatGPT
    @Default(.aiWarmupClaude) private var warmup
    @ObservedObject private var claude = AIAccountsManager.claude

    var body: some View {
        Form {
            Section {
                Toggle("Auto-switch Claude accounts", isOn: $autoClaude)
                Toggle("Auto-switch Codex accounts", isOn: $autoCodex)
                Picker("Strategy", selection: $strategy) {
                    ForEach(AISwitchStrategy.allCases) { Text($0.localizedName).tag($0) }
                }
                Picker("Windows that trigger a switch", selection: $windows) {
                    ForEach(AISwitchWindows.allCases) { Text($0.localizedName).tag($0) }
                }
            } header: {
                Text("Auto-switch")
            } footer: {
                Text("“Most quota left” stays on the current account until it nears a limit, then moves to the account with the most room. “Soonest weekly reset first” keeps you on the account whose weekly quota resets soonest, so it isn't wasted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                thresholdSlider(String(localized: "Threshold"), value: $threshold, allowsInherit: false)
                thresholdSlider(String(localized: "5-hour window"), value: $threshold5h, allowsInherit: true)
                thresholdSlider(String(localized: "Weekly window"), value: $thresholdWeekly, allowsInherit: true)
                HStack {
                    Text("Claude model limits")
                    Spacer()
                    TextField("Fable=40, Opus=60", text: $modelThresholds)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                Stepper(value: $cooldown, in: 1...60, step: 1) {
                    HStack { Text("Cooldown after a switch"); Spacer(); Text("\(Int(cooldown)) min").foregroundStyle(.secondary) }
                }
                Stepper(value: $hysteresis, in: 0...50, step: 5) {
                    HStack { Text("Required improvement"); Spacer(); Text("\(Int(hysteresis)) %").foregroundStyle(.secondary) }
                }
            } header: {
                Text("Thresholds")
            } footer: {
                Text("A switch happens when any window reaches its threshold. Model limits add a gate for a Claude model's own weekly limit (names as shown on the account cards); a name without a number uses the weekly threshold. The required improvement stops two accounts near the line from switching back and forth.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Switch the Claude Code CLI login", isOn: $switchCLI)
                Toggle("Switch the Claude desktop app login", isOn: $switchDesktop)
                    .disabled(!claude.desktopInstalled)
                Toggle("Reopen Claude after switching", isOn: $relaunchClaude)
                    .disabled(!switchDesktop || !claude.desktopInstalled)
                Toggle("CLI follows the desktop app's account", isOn: $cliFollowsDesktop)
                    .disabled(!claude.desktopInstalled)
                Toggle("Warm up idle accounts' five-hour window", isOn: $warmup)
            } header: {
                Text("Claude")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switching only replaces the login. Conversations, Code sessions and settings stay as they are. The desktop app is quit while its login is replaced.")
                    Text("When you sign in to another saved account in the Claude app, the CLI switches to it as well (within about a minute).")
                    if claude.desktopInstalled && !claude.desktopLoginVerified {
                        Text("Desktop app switching has not been verified on this Mac yet.").foregroundStyle(.orange)
                    }
                    Text("Warming sends one short Haiku prompt for an idle account so its five-hour window starts early. It uses real subscription quota and is off by default.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Restart ChatGPT after switching", isOn: $relaunchChatGPT)
            } header: {
                Text("Codex")
            } footer: {
                Text("ChatGPT (Codex) only reads its login when it starts, so it has to restart to use the new account. Running codex command-line sessions also need a restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("AI Accounts")
    }

    private func thresholdSlider(_ title: String, value: Binding<Double>, allowsInherit: Bool) -> some View {
        Slider(value: value, in: (allowsInherit ? 0 : 40)...99, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue == 0 && allowsInherit
                     ? String(localized: "Same as threshold")
                     : "\(Int(value.wrappedValue)) %")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
