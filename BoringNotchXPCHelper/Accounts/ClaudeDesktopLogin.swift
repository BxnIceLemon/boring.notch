//
//  ClaudeDesktopLogin.swift
//  BoringNotchXPCHelper
//
//  The Claude desktop app keeps its login in its Chromium profile at
//  ~/Library/Application Support/Claude. To switch accounts without touching conversations,
//  Code-tab sessions, settings or caches, only the *login pieces* are swapped:
//
//    1. Cookie rows for Anthropic hosts in every Chromium `Cookies` database of the profile
//       (the root one and the per-partition ones). `encrypted_value` is moved byte-for-byte:
//       it is encrypted with this Mac's "Claude Safe Storage" key, which is the same for every
//       account, so nothing is ever decrypted.
//    2. The login keys of `config.json` (spliced; every other key is preserved).
//
//  The lists below are the candidates found on disk; `verifiedLoginPieces` stays false until the
//  "step 0" before/after comparison confirms them, and the app labels desktop switching as
//  unverified until then. Must only run while Claude.app is fully quit.
//

import Foundation
import SQLite3

enum ClaudeDesktopLogin {
    static let verifiedLoginPieces = false

    /// Cookie hosts that carry the desktop app's session (suffix match on host_key).
    static let loginCookieHosts = ["claude.ai", "claude.com", "anthropic.com"]
    /// `config.json` keys that hold or describe the signed-in account.
    static let loginConfigKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid", "bootSideSessions"]

    static var configURL: URL { AccountPaths.claudeDesktopData.appendingPathComponent("config.json") }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: AccountPaths.claudeDesktopData.path)
    }

    /// Account uuid the desktop app last signed in with (`lastKnownAccountUuid`).
    static func currentAccountUuid() -> String? {
        (try? JSONFile.read(configURL))??.string("lastKnownAccountUuid")
    }

    // MARK: Capture / restore

    /// Reads the login pieces. Claude.app must be quit (its databases are otherwise in use).
    static func capture() throws -> JSONObject {
        var databases: [JSONObject] = []
        for db in cookieDatabases() {
            let rows = try CookieDB(url: db.url).loginRows()
            databases.append(["path": db.relativePath, "columns": rows.columns, "rows": rows.rows])
        }
        var config: JSONObject = [:]
        if let current = try JSONFile.read(configURL) {
            for key in loginConfigKeys where current[key] != nil { config[key] = current[key] }
        }
        return ["version": 1, "cookieDatabases": databases, "config": config, "capturedAt": ISODate.string(Date())]
    }

    /// Replaces the current login pieces with `pieces` (or clears them when nil, which leaves the
    /// app at its sign-in screen). Everything else in the profile is left untouched.
    static func restore(_ pieces: JSONObject?) throws {
        let saved = (pieces?["cookieDatabases"] as? [JSONObject]) ?? []
        let byPath = Dictionary(saved.compactMap { db in (db["path"] as? String).map { ($0, db) } },
                                uniquingKeysWith: { first, _ in first })
        // Every current database is rewritten (rows from `pieces`, or none). A saved database whose
        // partition no longer exists is skipped rather than recreated.
        for db in cookieDatabases() {
            let entry = byPath[db.relativePath]
            try CookieDB(url: db.url).replaceLoginRows(columns: entry?["columns"] as? [String] ?? [],
                                                       rows: entry?["rows"] as? [[Any]] ?? [])
        }

        var config = try JSONFile.read(configURL) ?? [:]
        for key in loginConfigKeys { config.removeValue(forKey: key) }
        for (key, value) in (pieces?["config"] as? JSONObject) ?? [:] where loginConfigKeys.contains(key) {
            config[key] = value
        }
        try PrivateFiles.atomicWriteJSON(config, to: configURL, pretty: false)
    }

    // MARK: Cookie databases

    private struct DatabaseLocation { let url: URL; let relativePath: String }

    /// The root `Cookies` database plus `Partitions/*/Cookies`. Caches are never scanned.
    private static func cookieDatabases() -> [DatabaseLocation] {
        let root = AccountPaths.claudeDesktopData
        var found: [DatabaseLocation] = []
        let rootDB = root.appendingPathComponent("Cookies")
        if FileManager.default.fileExists(atPath: rootDB.path) { found.append(.init(url: rootDB, relativePath: "Cookies")) }
        let partitions = root.appendingPathComponent("Partitions", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: partitions.path)) ?? [] {
            let db = partitions.appendingPathComponent(name).appendingPathComponent("Cookies")
            if FileManager.default.fileExists(atPath: db.path) {
                found.append(.init(url: db, relativePath: "Partitions/\(name)/Cookies"))
            }
        }
        return found
    }

    static func isLoginHost(_ host: String) -> Bool {
        let bare = host.hasPrefix(".") ? String(host.dropFirst()) : host
        return loginCookieHosts.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }
}

/// Minimal SQLite access to a Chromium cookie store.
private final class CookieDB {
    private var db: OpaquePointer?

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw AccountsError("desktop_cookies", "cannot open \(url.lastPathComponent): \(message)")
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    private func columns() throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(cookies)", -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(stmt, 1))) }
        return names
    }

    /// Rows for login hosts, values encoded for JSON: blobs as {"b64": ...}, NULL as NSNull.
    func loginRows() throws -> (columns: [String], rows: [[Any]]) {
        let cols = try columns()
        guard let hostIndex = cols.firstIndex(of: "host_key") else { return (cols, []) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM cookies", -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        var rows: [[Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(stmt, Int32(hostIndex)))
            guard ClaudeDesktopLogin.isLoginHost(host) else { continue }
            var row: [Any] = []
            for i in 0..<Int32(cols.count) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(stmt, i))
                    let data = count > 0 ? Data(bytes: sqlite3_column_blob(stmt, i), count: count) : Data()
                    row.append(["b64": data.base64EncodedString()])
                default: row.append(NSNull())
                }
            }
            rows.append(row)
        }
        return (cols, rows)
    }

    /// In one transaction: delete every login-host row, then insert `rows`. Columns are matched
    /// by name so a Chromium schema change only drops columns the current schema lacks.
    func replaceLoginRows(columns saved: [String], rows: [[Any]]) throws {
        let current = try columns()
        try exec("BEGIN IMMEDIATE")
        do {
            try deleteLoginRows()
            let usable = saved.enumerated().filter { current.contains($0.element) }
            if !rows.isEmpty, !usable.isEmpty {
                let names = usable.map { "\"\($0.element)\"" }.joined(separator: ",")
                let marks = Array(repeating: "?", count: usable.count).joined(separator: ",")
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO cookies (\(names)) VALUES (\(marks))", -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
                defer { sqlite3_finalize(stmt) }
                for row in rows {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    for (position, column) in usable.enumerated() where column.offset < row.count {
                        try bind(row[column.offset], to: stmt, at: Int32(position + 1))
                    }
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw lastError() }
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func deleteLoginRows() throws {
        // Collect matching hosts first so the suffix rule lives in one place (Swift).
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT DISTINCT host_key FROM cookies", -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        var hosts: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let host = String(cString: sqlite3_column_text(stmt, 0))
            if ClaudeDesktopLogin.isLoginHost(host) { hosts.append(host) }
        }
        sqlite3_finalize(stmt)
        for host in hosts {
            var del: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM cookies WHERE host_key = ?", -1, &del, nil) == SQLITE_OK else { throw lastError() }
            sqlite3_bind_text(del, 1, host, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let rc = sqlite3_step(del)
            sqlite3_finalize(del)
            guard rc == SQLITE_DONE else { throw lastError() }
        }
    }

    private func bind(_ value: Any, to stmt: OpaquePointer?, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case is NSNull: sqlite3_bind_null(stmt, index)
        case let blob as [String: Any]:
            let data = Data(base64Encoded: blob["b64"] as? String ?? "") ?? Data()
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
        case let text as String: sqlite3_bind_text(stmt, index, text, -1, transient)
        case let number as NSNumber:
            if CFNumberIsFloatType(number) { sqlite3_bind_double(stmt, index, number.doubleValue) }
            else { sqlite3_bind_int64(stmt, index, number.int64Value) }
        default: sqlite3_bind_null(stmt, index)
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> AccountsError {
        AccountsError("desktop_cookies", String(cString: sqlite3_errmsg(db)))
    }
}
