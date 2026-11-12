//
//  ProperLockfile.swift
//  BoringNotchXPCHelper
//
//  Cooperates with Claude Code's own advisory locks (npm `proper-lockfile`), ported from ccswap's
//  claude_locks.py. The lock is a directory; mkdir atomicity is the mutex; a live holder touches
//  the directory mtime every 5s. Claude Code refreshes its OAuth token under
//  `<config-home>/.oauth_refresh.lock` then `~/.claude.lock` (stale after 60s), and writes
//  `~/.claude.json` under `~/.claude.json.lock` (stale after 10s).
//
//  Holding these while swapping credentials closes the race with a running Claude Code: a refresh
//  that started before us finishes first (and our backup captures the rotated token); one that
//  starts after us re-reads the store under the lock, sees the swapped token and aborts.
//

import Foundation

final class ProperLockfile {
    static let credentialsStaleness: TimeInterval = 60
    static let configStaleness: TimeInterval = 10
    private static let touchInterval: TimeInterval = 3
    private static let defaultTimeout: TimeInterval = 9
    private static let takeoverStaleness: TimeInterval = 5

    private let path: URL
    private var touchTimer: DispatchSourceTimer?

    private init(path: URL) { self.path = path }

    static func acquire(_ path: URL, staleness: TimeInterval, timeout: TimeInterval = defaultTimeout) throws -> ProperLockfile {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let start = Date()
        while true {
            if mkdir(path.path, 0o755) == 0 { break }
            guard errno == EEXIST else {
                throw AccountsError("lock_failed", "could not create \(path.lastPathComponent)")
            }
            if Date().timeIntervalSince(start) > timeout {
                throw AccountsError("claude_busy", "Claude Code is refreshing its login (\(path.lastPathComponent) is held). Try again in a few seconds.")
            }
            guard let mtime = modificationDate(path) else { continue }   // released between mkdir and stat
            if Date().timeIntervalSince(mtime) > staleness {
                if !removeIfStillStale(path, staleness: staleness) { usleep(50_000) }
                continue
            }
            usleep(useconds_t(250_000 + Int.random(in: 0..<250_000)))
        }
        let lock = ProperLockfile(path: path)
        lock.startTouching()
        return lock
    }

    func release() {
        touchTimer?.cancel()
        touchTimer = nil
        rmdir(path.path)
    }

    private func startTouching() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + Self.touchInterval, repeating: Self.touchInterval)
        timer.setEventHandler { [path] in utimes(path.path, nil) }
        timer.resume()
        touchTimer = timer
    }

    private static func modificationDate(_ path: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date
    }

    /// Two waiters that both saw the same dead holder must not both rmdir: the second would
    /// remove the first one's fresh lock. Takeovers are serialized through a sibling directory.
    private static func removeIfStillStale(_ path: URL, staleness: TimeInterval) -> Bool {
        let takeover = path.deletingLastPathComponent().appendingPathComponent(path.lastPathComponent + ".takeover")
        if mkdir(takeover.path, 0o755) != 0 {
            if let mtime = modificationDate(takeover), Date().timeIntervalSince(mtime) > takeoverStaleness {
                rmdir(takeover.path)
            }
            return false
        }
        defer { rmdir(takeover.path) }
        guard let mtime = modificationDate(path), Date().timeIntervalSince(mtime) > staleness else { return false }
        return rmdir(path.path) == 0
    }
}

enum ClaudeCodeLocks {
    static var oauthRefreshLock: URL { AccountPaths.claudeConfigHome.appendingPathComponent(".oauth_refresh.lock") }
    static var legacyCredentialsLock: URL {
        let home = AccountPaths.claudeConfigHome
        return home.deletingLastPathComponent().appendingPathComponent(home.lastPathComponent + ".lock")
    }
    static var configLock: URL {
        let config = AccountPaths.claudeGlobalConfig
        return config.deletingLastPathComponent().appendingPathComponent(config.lastPathComponent + ".lock")
    }

    /// The two locks Claude Code itself holds while refreshing its OAuth token (network inside is
    /// fine: they are touched every few seconds and only go stale after 60s).
    static func withCredentials<T>(_ body: () throws -> T) throws -> T {
        let primary = try ProperLockfile.acquire(oauthRefreshLock, staleness: ProperLockfile.credentialsStaleness)
        defer { primary.release() }
        let legacy = try ProperLockfile.acquire(legacyCredentialsLock, staleness: ProperLockfile.credentialsStaleness)
        defer { legacy.release() }
        return try body()
    }

    /// Credential locks in Claude Code's own order, then the config lock. No network inside.
    static func withAll<T>(_ body: () throws -> T) throws -> T {
        let primary = try ProperLockfile.acquire(oauthRefreshLock, staleness: ProperLockfile.credentialsStaleness)
        defer { primary.release() }
        let legacy = try ProperLockfile.acquire(legacyCredentialsLock, staleness: ProperLockfile.credentialsStaleness)
        defer { legacy.release() }
        let config = try ProperLockfile.acquire(configLock, staleness: ProperLockfile.configStaleness)
        defer { config.release() }
        return try body()
    }
}
