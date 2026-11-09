//
//  NetEaseMenuControl.swift
//  BoringNotchXPCHelper
//
//  NetEase Cloud Music (com.netease.163music) has no AppleScript dictionary and no local API.
//  Besides the system Now Playing info, the only control channel is its own "控制 / Controls"
//  menu, reached through the Accessibility API. This runs in the non-sandboxed helper because
//  that is the process holding the Accessibility trust.
//
//  Menu titles come from NetEase's own language packs (it ships zh-Hans and en only) and match
//  what other open-source controllers verified (e.g. Yudaotor/lyrimuse PlaybackMenuControl).
//  Items are matched by title (plus ⌘L for Like), never by position, because updates reorder menus.
//

import AppKit
import ApplicationServices
import Foundation

enum NetEaseMenuControl {
    static let bundleID = "com.netease.163music"

    enum Command: String {
        case playPause
        case nextTrack
        case previousTrack
        case favorite
    }

    /// Per-message AX timeout, so a hung NetEase can't stall the helper.
    private static let messagingTimeout: Float = 0.3

    // MARK: Title matching (pure)

    static func command(forTitle raw: String) -> Command? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "播放", "暂停", "播放/暂停", "Play", "Pause", "Play/Pause": return .playPause
        case "下一个", "Next": return .nextTrack
        case "上一个", "Previous": return .previousTrack
        case "喜欢歌曲", "取消喜欢", "Like", "Dislike": return .favorite
        default: return nil
        }
    }

    /// The Like item's title is the state: "取消喜欢"/"Dislike" means the current track is liked.
    static func favorited(forTitle raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "取消喜欢", "Dislike": return true
        case "喜欢歌曲", "Like": return false
        default: return nil
        }
    }

    // MARK: AX access

    /// Finds the menu item for `command`. Only accepts a top-level menu that contains at least two
    /// recognised transport items, since "Play"/"Next" are common words in English menus.
    static func item(for target: Command) -> (element: AXUIElement, title: String)? {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        guard let menuBar = element(appElement, kAXMenuBarAttribute) else { return nil }

        for top in menuChildren(menuBar) {
            let items = menuChildren(top).map { ($0, string($0, kAXTitleAttribute) ?? "") }
            let recognised = Set(items.compactMap { command(forTitle: $0.1) })
            guard recognised.count >= 2 else { continue }
            for (element, title) in items where command(forTitle: title) == target {
                if target == .favorite, string(element, "AXMenuItemCmdChar")?.uppercased() != "L" { continue }
                return (element, title)
            }
        }
        return nil
    }

    static func press(_ target: Command) -> Bool {
        guard let found = item(for: target) else { return false }
        var enabled: AnyObject?
        if AXUIElementCopyAttributeValue(found.element, kAXEnabledAttribute as CFString, &enabled) == .success,
           (enabled as? Bool) == false {
            return false
        }
        return AXUIElementPerformAction(found.element, kAXPressAction as CFString) == .success
    }

    static func readFavorited() -> Bool? {
        item(for: .favorite).flatMap { favorited(forTitle: $0.title) }
    }

    /// Sets Like to `value`. Pressing toggles, so read first; then wait for the title to flip
    /// (NetEase updates it within ~1.5s). Returns whether the requested state was reached.
    static func setFavorited(_ value: Bool) -> Bool {
        guard let found = item(for: .favorite), let now = favorited(forTitle: found.title) else { return false }
        if now == value { return true }
        guard press(.favorite) else { return false }
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.1)
            if readFavorited() == value { return true }
        }
        return false
    }

    // MARK: Small AX helpers

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let result = value as! AXUIElement
        AXUIElementSetMessagingTimeout(result, messagingTimeout)
        return result
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Children of a menu-bar item / menu item, skipping the AXMenu layer in between.
    private static func menuChildren(_ e: AXUIElement) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children.flatMap { child -> [AXUIElement] in
            AXUIElementSetMessagingTimeout(child, messagingTimeout)
            return string(child, kAXRoleAttribute) == kAXMenuRole ? menuChildren(child) : [child]
        }
    }
}
