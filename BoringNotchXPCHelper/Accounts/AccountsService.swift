//
//  AccountsService.swift
//  BoringNotchXPCHelper
//
//  Single JSON entry point for the AI account manager, so new operations don't need XPC protocol
//  changes. Request:  {"provider": "claude"|"codex", "op": "...", ...arguments}
//  Reply:             {"ok": true, "result": {...}}  or  {"ok": false, "code": "...", "message": "..."}
//  All work runs on one serial queue: credential operations never interleave.
//

import Foundation

enum AccountsService {
    static let queue = DispatchQueue(label: "theboringteam.boringnotch.accounts")
    private static let claude = ClaudeAccounts()
    private static let codex = CodexAccounts()
    private static let codexLogin = CodexLogin(accounts: codex)
    private static let claudeLogin = ClaudeLogin(accounts: claude)

    static func handle(_ request: Data, reply: @escaping (Data) -> Void) {
        queue.async {
            let response: JSONObject
            do {
                guard let json = JSONFile.parse(request) else { throw AccountsError("bad_request", "request is not JSON") }
                response = ["ok": true, "result": try dispatch(json)]
            } catch let error as AccountsError {
                response = ["ok": false, "code": error.code, "message": error.message]
            } catch {
                response = ["ok": false, "code": "internal", "message": "\(error)"]
            }
            reply((try? JSONFile.data(response)) ?? Data(#"{"ok":false,"code":"internal"}"#.utf8))
        }
    }

    private static func dispatch(_ request: JSONObject) throws -> JSONObject {
        let op = request.string("op") ?? ""
        let id = request.string("id")
        func requireID() throws -> String {
            guard let id else { throw AccountsError("bad_request", "missing account id") }
            return id
        }
        switch (request.string("provider"), op) {
        case ("claude", "status"): return try claude.status()
        case ("claude", "addCurrent"): return try claude.addCurrent()
        case ("claude", "switch"):
            return try claude.switchTo(try requireID(), cli: request["cli"] as? Bool ?? true,
                                       desktop: request["desktop"] as? Bool ?? false,
                                       relaunchDesktop: request["relaunchDesktop"] as? Bool ?? true)
        case ("claude", "loginStart"): return try claudeLogin.start()
        case ("claude", "loginPoll"): return try claudeLogin.poll(request.string("loginId") ?? "")
        case ("claude", "loginCode"): claudeLogin.submitCode(request.string("loginId") ?? "", request.string("code") ?? ""); return [:]
        case ("claude", "loginCancel"): claudeLogin.cancel(request.string("loginId") ?? ""); return [:]
        case ("claude", "usage"): return try claude.usage(try requireID())
        case ("claude", "warmup"): return try claude.warmup(try requireID())
        case ("claude", "remove"): try claude.remove(try requireID()); return [:]
        case ("claude", "update"):
            try claude.update(try requireID(), alias: request["alias"] as? String, disabled: request["disabled"] as? Bool)
            return [:]
        case ("claude", "move"): try claude.move(try requireID(), to: request["index"] as? Int ?? 0); return [:]

        case ("codex", "status"): return try codex.status()
        case ("codex", "addCurrent"): return try codex.addCurrent()
        case ("codex", "switch"): return try codex.switchTo(try requireID(), restartApp: request["restartApp"] as? Bool ?? false)
        case ("codex", "loginStart"): return try codexLogin.start()
        case ("codex", "loginPoll"): return try codexLogin.poll(request.string("loginId") ?? "")
        case ("codex", "loginCancel"): codexLogin.cancel(request.string("loginId") ?? ""); return [:]
        case ("codex", "restartApp"): return codex.restartApp()
        case ("codex", "usage"): return try codex.usage(try requireID())
        case ("codex", "redeemReset"): return try codex.redeemReset(try requireID())
        case ("codex", "remove"): try codex.remove(try requireID()); return [:]
        case ("codex", "update"):
            try codex.update(try requireID(), alias: request["alias"] as? String, disabled: request["disabled"] as? Bool)
            return [:]
        case ("codex", "move"): try codex.move(try requireID(), to: request["index"] as? Int ?? 0); return [:]

        default: throw AccountsError("bad_request", "unknown operation \(op)")
        }
    }
}
