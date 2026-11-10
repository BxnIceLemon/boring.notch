//
//  AccountStore.swift
//  BoringNotchXPCHelper
//
//  Our own library of saved logins, independent of ccswap:
//    ~/Library/Application Support/BoringNotch/Accounts/<provider>/
//        index.json                 metadata only (no secrets)
//        <id>/credentials.json      Claude Code CLI credential (claudeAiOauth JSON)
//        <id>/oauthAccount.json     the ~/.claude.json `oauthAccount` block for that login
//        <id>/desktop-login/        Claude desktop app login pieces
//        <id>/auth.json             Codex auth.json
//        stash/                     safety copies of logins we replaced (never deleted by us)
//  Directories are 0700, files 0600, every write is temp-file + rename.
//

import Foundation

enum Provider: String { case claude, codex }

struct SavedAccount {
    var id: String
    var email: String
    var accountUuid: String?      // Claude account uuid / ChatGPT account id
    var organizationUuid: String?
    var organizationName: String?
    var plan: String?
    var alias: String?
    var disabled: Bool
    var addedAt: Date

    init(id: String = UUID().uuidString, email: String) {
        self.id = id; self.email = email; disabled = false; addedAt = Date()
    }

    init?(json: JSONObject) {
        guard let id = json.string("id"), let email = json.string("email") else { return nil }
        self.id = id
        self.email = email
        accountUuid = json.string("accountUuid")
        organizationUuid = json.string("organizationUuid")
        organizationName = json.string("organizationName")
        plan = json.string("plan")
        alias = json.string("alias")
        disabled = json["disabled"] as? Bool ?? false
        addedAt = ISODate.parse(json["addedAt"]) ?? Date()
    }

    var json: JSONObject {
        var out: JSONObject = ["id": id, "email": email, "disabled": disabled, "addedAt": ISODate.string(addedAt)]
        if let accountUuid { out["accountUuid"] = accountUuid }
        if let organizationUuid { out["organizationUuid"] = organizationUuid }
        if let organizationName { out["organizationName"] = organizationName }
        if let plan { out["plan"] = plan }
        if let alias { out["alias"] = alias }
        return out
    }
}

final class AccountStore {
    let provider: Provider
    private let root: URL
    private var lockFD: Int32 = -1

    init(_ provider: Provider) {
        self.provider = provider
        root = AccountPaths.store.appendingPathComponent(provider.rawValue, isDirectory: true)
    }

    // MARK: Locking (serializes helper instances; the helper also runs all work on one queue)

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try PrivateFiles.ensureDirectory(root)
        let fd = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw AccountsError("lock_failed", "account store lock") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AccountsError("lock_failed", "account store lock") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: Index

    func accounts() throws -> [SavedAccount] {
        guard let index = try JSONFile.read(root.appendingPathComponent("index.json")),
              let list = index["accounts"] as? [JSONObject] else { return [] }
        return list.compactMap(SavedAccount.init(json:))
    }

    func save(_ accounts: [SavedAccount]) throws {
        try PrivateFiles.ensureDirectory(root)
        try PrivateFiles.atomicWriteJSON(["version": 1, "accounts": accounts.map(\.json)],
                                         to: root.appendingPathComponent("index.json"))
    }

    func account(_ id: String) throws -> SavedAccount {
        guard let found = try accounts().first(where: { $0.id == id }) else {
            throw AccountsError("unknown_account", "account not found")
        }
        return found
    }

    func update(_ id: String, _ change: (inout SavedAccount) -> Void) throws {
        var list = try accounts()
        guard let index = list.firstIndex(where: { $0.id == id }) else {
            throw AccountsError("unknown_account", "account not found")
        }
        change(&list[index])
        try save(list)
    }

    // MARK: Per-account secret files

    func directory(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func file(_ id: String, _ name: String) -> URL { directory(id).appendingPathComponent(name) }

    func readText(_ id: String, _ name: String) throws -> String? {
        let url = file(id, name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writeText(_ id: String, _ name: String, _ text: String) throws {
        try PrivateFiles.ensureDirectory(directory(id))
        try PrivateFiles.atomicWrite(Data(text.utf8), to: file(id, name))
    }

    func readJSON(_ id: String, _ name: String) throws -> JSONObject? { try JSONFile.read(file(id, name)) }

    func writeJSON(_ id: String, _ name: String, _ object: JSONObject) throws {
        try PrivateFiles.ensureDirectory(directory(id))
        try PrivateFiles.atomicWriteJSON(object, to: file(id, name))
    }

    func removeAccountFiles(_ id: String) throws {
        let dir = directory(id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    // MARK: Stash

    /// Keeps a copy of a login we are about to overwrite. Never deleted automatically.
    func stash(_ payload: JSONObject, reason: String) throws {
        let dir = root.appendingPathComponent("stash", isDirectory: true)
        try PrivateFiles.ensureDirectory(dir)
        let stamp = ISODate.string(Date()).replacingOccurrences(of: ":", with: "-")
        var body = payload
        body["reason"] = reason
        body["stashedAt"] = ISODate.string(Date())
        try PrivateFiles.atomicWriteJSON(body, to: dir.appendingPathComponent("\(stamp)-\(reason)-\(UUID().uuidString.prefix(8)).json"))
    }
}
