//
//  AccountsCommon.swift
//  BoringNotchXPCHelper
//
//  Shared plumbing for the AI account manager (a native port of ccswap's account features):
//  paths, JSON helpers, atomic private file writes, bounded subprocesses and blocking HTTP.
//
//  Everything here runs in the non-sandboxed XPC helper, on `AccountsService.queue`.
//  Credential bytes never leave the helper; the app only receives metadata and usage.
//

import Foundation

struct AccountsError: Error, CustomStringConvertible {
    /// Stable machine-readable code the app can branch on (e.g. "claude_cli_not_logged_in").
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var description: String { "\(code): \(message)" }
}

typealias JSONObject = [String: Any]

enum AccountPaths {
    /// $HOME first, like Claude Code (os.homedir) and Codex, so all three agree on file locations.
    static var home: URL {
        if let path = ProcessInfo.processInfo.environment["HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Our own account library. Directories 0700, files 0600.
    static var store: URL {
        home.appendingPathComponent("Library/Application Support/BoringNotch/Accounts", isDirectory: true)
    }

    // Claude Code CLI
    static var claudeConfigHome: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }
    /// `~/.claude.json` — shared by the CLI and the desktop app's built-in Claude Code.
    static var claudeGlobalConfig: URL { home.appendingPathComponent(".claude.json") }

    // Claude desktop app
    static var claudeDesktopData: URL {
        home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    // Codex (ChatGPT.app / codex CLI)
    static var codexHome: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent(".codex", isDirectory: true)
    }
    static var codexAuth: URL { codexHome.appendingPathComponent("auth.json") }
    static let chatGPTBundleID = "com.openai.codex"
}

enum JSONFile {
    static func parse(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func parse(_ text: String) -> JSONObject? {
        text.data(using: .utf8).flatMap(parse)
    }

    /// nil when the file is absent; throws when it exists but cannot be read or parsed,
    /// so a torn file is never mistaken for "no file".
    static func read(_ url: URL) throws -> JSONObject? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = parse(data) else {
            throw AccountsError("bad_json", "\(url.lastPathComponent) is not valid JSON")
        }
        return object
    }

    static func data(_ object: Any, pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    static func string(_ object: Any) throws -> String {
        String(decoding: try data(object), as: UTF8.self)
    }
}

enum PrivateFiles {
    static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Writes by temp file + rename in the same directory, so readers (including a running
    /// Claude Code or Codex watching the file) never see a truncated file.
    static func atomicWrite(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        try ensureDirectoryExists(dir)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: permissions]) else {
            throw AccountsError("write_failed", "could not write \(url.lastPathComponent)")
        }
        if rename(tmp.path, url.path) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw AccountsError("write_failed", "could not replace \(url.lastPathComponent): \(err)")
        }
    }

    static func atomicWriteJSON(_ object: Any, to url: URL, pretty: Bool = true) throws {
        try atomicWrite(try JSONFile.data(object, pretty: pretty), to: url)
    }

    /// Keeps the target directory's own permissions (e.g. ~/.codex) instead of forcing 0700.
    private static func ensureDirectoryExists(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}

enum Subprocess {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Runs `executable` with a hard timeout. Secrets go through `stdin`, never argv.
    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil,
                    environment: [String: String]? = nil, currentDirectory: URL? = nil,
                    timeout: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input

        // Drain pipes concurrently so a chatty child can't block on a full pipe buffer.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 1)
            throw AccountsError("timeout", "\((executable as NSString).lastPathComponent) timed out")
        }
        _ = group.wait(timeout: .now() + 2)
        return Result(status: process.terminationStatus, stdout: outData, stderr: errData)
    }
}

enum HTTP {
    struct Response {
        let status: Int
        let data: Data
        let headers: [AnyHashable: Any]
        var json: JSONObject? { JSONFile.parse(data) }
        var retryAfter: Double? {
            for (key, value) in headers where (key as? String)?.lowercased() == "retry-after" {
                if let text = value as? String, let seconds = Double(text.trimmingCharacters(in: .whitespaces)) {
                    return max(0, seconds)
                }
            }
            return nil
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// Blocking request (the helper does all account work on one serial queue).
    static func send(_ url: String, method: String = "GET", headers: [String: String] = [:],
                     json body: JSONObject? = nil, timeout: TimeInterval = 10) throws -> Response {
        guard let target = URL(string: url) else { throw AccountsError("bad_url", url) }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = try JSONFile.data(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Response, Error> = .failure(AccountsError("network", "no response"))
        session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(AccountsError((error as? URLError)?.code == .timedOut ? "timeout" : "network",
                                                error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                result = .success(Response(status: http.statusCode, data: data ?? Data(),
                                           headers: http.allHeaderFields))
            }
            semaphore.signal()
        }.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            throw AccountsError("timeout", "request timed out")
        }
        return try result.get()
    }
}

enum JWT {
    /// Decodes a JWT payload without verifying it (used only to read identity claims locally).
    static func claims(_ token: Any?) -> JSONObject {
        guard let token = token as? String else { return [:] }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return [:] }
        return JSONFile.parse(data) ?? [:]
    }
}

enum ISODate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ value: Any?) -> Date? {
        if let number = value as? Double, number.isFinite { return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number) }
        if let number = value as? Int { return Date(timeIntervalSince1970: Double(number) > 1e12 ? Double(number) / 1000 : Double(number)) }
        guard let text = value as? String, !text.isEmpty else { return nil }
        return withFraction.date(from: text) ?? plain.date(from: text)
    }

    static func string(_ date: Date) -> String { plain.string(from: date) }
}

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func string(_ key: String) -> String? {
        guard let value = self[key] as? String, !value.isEmpty else { return nil }
        return value
    }
    func number(_ key: String) -> Double? {
        if self[key] is Bool { return nil }
        if let value = self[key] as? Double, value.isFinite { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? String, let parsed = Double(value), parsed.isFinite { return parsed }
        return nil
    }
}
