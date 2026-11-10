//
//  SecurityCLI.swift
//  BoringNotchXPCHelper
//
//  Keychain access through /usr/bin/security, like ccswap's macos_keychain.py.
//  Claude Code creates its "Claude Code-credentials" item with the `security` tool, so the tool
//  is in the item's ACL and reading/writing it this way never shows a Keychain prompt. The secret
//  is passed hex-encoded on `security -i`'s stdin so it never appears in process arguments.
//

import Foundation

enum SecurityCLI {
    private static let tool = "/usr/bin/security"   // absolute: a PATH-injected `security` must not see secrets
    private static let timeout: TimeInterval = 10
    private static let notFound: Int32 = 44
    /// `security -i` reads stdin with a 4096-byte line buffer.
    private static let stdinLineLimit = 4096

    /// Mirrors Claude Code's getUsername(): $USER, then the OS user name.
    static var accountName: String {
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty { return user }
        return NSUserName().isEmpty ? "claude-code-user" : NSUserName()
    }

    /// nil when the item does not exist; throws on any other failure (locked, denied, timeout),
    /// so a genuine miss is never confused with a transient error.
    static func read(service: String, account: String = accountName) throws -> String? {
        let result = try Subprocess.run(tool, ["find-generic-password", "-a", account, "-w", "-s", service],
                                        timeout: timeout)
        if result.status == 0 {
            var text = result.stdoutText
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }
        if result.status == notFound { return nil }
        throw AccountsError("keychain", "security find-generic-password failed (\(result.status))")
    }

    static func write(service: String, account: String = accountName, secret: String) throws {
        let hex = Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \(quote(account)) -s \(quote(service)) -X \(hex)\n"
        let result: Subprocess.Result
        if command.utf8.count <= stdinLineLimit {
            result = try Subprocess.run(tool, ["-i"], stdin: Data(command.utf8), timeout: timeout)
        } else {
            // Too long for the stdin line buffer. Hex in argv still beats silent truncation.
            result = try Subprocess.run(tool, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex],
                                        timeout: timeout)
        }
        guard result.status == 0 else {
            throw AccountsError("keychain", "security add-generic-password failed (\(result.status))")
        }
    }

    static func delete(service: String, account: String = accountName) throws {
        let result = try Subprocess.run(tool, ["delete-generic-password", "-a", account, "-s", service], timeout: timeout)
        guard result.status == 0 || result.status == notFound else {
            throw AccountsError("keychain", "security delete-generic-password failed (\(result.status))")
        }
    }

    /// `security -i` re-parses each line shell-style.
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
