// -----------------------------------------------------------------------------
//  OrcaSignIn — "Sign in with OrcaRouter" (OAuth 2.0 Authorization Code + PKCE).
//
//  Lets the user get an OrcaRouter API key with no manual copy-paste:
//  click → browser approval → the key lands in the macOS Keychain.
//
//  Flow (docs.orcarouter.ai/getting-started/sign-in-with-orcarouter):
//    1. verifier (43-128 chars) + challenge = base64url(SHA-256(verifier)).
//    2. Open https://www.orcarouter.ai/auth with callback_url (loopback),
//       code_challenge(_method=S256), state, app_name, scope=api, ref (+ app_id
//       once OrcaRouter issues one under the partner console).
//    3. The browser redirects to http://127.0.0.1:<port>/cb?code=&state= —
//       verify state, answer with a small "you can close this tab" page.
//    4. POST {code, code_verifier} to the token endpoint → {key, user_id,
//       scope}; store the key in the Keychain (never logged, never to disk).
//
//  Pure Foundation / CryptoKit / Network / AppKit — no UI dependencies, so it
//  can be exercised standalone by a test harness (see Tools/test in the repo
//  docs: compile with OrcaRouter.swift + a small main).
//
//  Security notes: loopback-only listener; codes are single-use and expire in
//  10 minutes; a mismatched `state` aborts without exchanging; the verifier
//  and key never leave the process except as part of the documented exchange.
// -----------------------------------------------------------------------------

import Foundation
import CryptoKit
import Network
import AppKit

final class OrcaSignInController {

    // MARK: UI callbacks (always invoked on the main thread)

    /// Called once the loopback listener is up and the browser is opening.
    var onWaiting: (() -> Void)?
    /// Final result: (message, ok). ok=true means the key was minted AND saved.
    var onFinish: ((_ message: String, _ ok: Bool) -> Void)?

    // MARK: Internal state (readable for the test harness / UI)

    private(set) var verifier: String = ""
    private(set) var stateToken: String = ""
    /// Fully-built authorization URL once the listener is ready (empty before).
    private(set) var authURLString: String = ""
    private(set) var active = false

    private var listener: NWListener?
    private var timeoutWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.llama-menubar.orca-signin")

    // MARK: - Public API

    /// Start a fresh sign-in attempt. Cancels any previous one.
    /// - Parameter openBrowser: false = don't launch the browser (tests).
    func start(openBrowser: Bool = true) {
        cancel()
        verifier = Self.randomBase64URL(bytes: 32)
        stateToken = Self.randomBase64URL(bytes: 16)
        let challenge = Self.challenge(for: verifier)

        do {
            let l = try Self.makeListener()
            listener = l
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port?.rawValue else {
                        self.finish(status: "✗ Could not determine the local callback port.", ok: false)
                        return
                    }
                    guard let url = Self.buildAuthURL(callback: "http://127.0.0.1:\(port)/cb",
                                                      challenge: challenge,
                                                      state: self.stateToken) else {
                        self.finish(status: "✗ Could not build the authorization URL.", ok: false)
                        return
                    }
                    self.authURLString = url.absoluteString
                    self.active = true
                    self.scheduleTimeout()
                    DispatchQueue.main.async { self.onWaiting?() }
                    if openBrowser { NSWorkspace.shared.open(url) }
                case .failed(let err):
                    self.finish(status: "✗ Local listener failed: \(err.localizedDescription)", ok: false)
                default:
                    break
                }
            }
            l.start(queue: queue)
        } catch {
            finish(status: "✗ Could not start the local listener: \(error.localizedDescription)", ok: false)
        }
    }

    /// Abort the attempt (user pressed Cancel, window closed, …).
    func cancel() {
        timeoutWork?.cancel()
        timeoutWork = nil
        listener?.cancel()
        listener = nil
        active = false
    }

    // MARK: - HTTP callback handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { conn.cancel(); return }
            guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            // Request line: "GET /cb?code=…&state=… HTTP/1.1"
            let requestLine = request.split(separator: "\r\n", maxSplits: 1,
                                            omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let pieces = requestLine.split(separator: " ")
            let pathAndQuery = pieces.count >= 2 ? String(pieces[1]) : ""
            let path = pathAndQuery.split(separator: "?", maxSplits: 1,
                                          omittingEmptySubsequences: false).first.map(String.init) ?? pathAndQuery
            let query = Self.queryParams(from: pathAndQuery)

            guard path == "/cb" else {
                // Favicon or stray request — answer politely, keep waiting.
                self.respond(conn, html: Self.page(title: "LM Switcher", text: "Waiting for the sign-in callback…"))
                return
            }

            if let err = query["error"] {
                self.respond(conn, html: Self.page(title: "Sign-in cancelled",
                                                   text: "You can close this tab and return to LM Switcher."))
                self.finish(status: err == "access_denied"
                            ? "✗ Approval was denied in the browser."
                            : "✗ OrcaRouter returned an error: \(err)", ok: false)
                return
            }

            guard let code = query["code"] else {
                self.respond(conn, html: Self.page(title: "LM Switcher",
                                                   text: "Waiting for the sign-in callback…"))
                return
            }

            guard query["state"] == self.stateToken else {
                self.respond(conn, html: Self.page(title: "Sign-in failed",
                                                   text: "Security check failed — this attempt was refused. Try again from LM Switcher."))
                self.finish(status: "✗ State check failed — try again.", ok: false)
                return
            }

            self.respond(conn, html: Self.page(title: "You're signed in",
                                               text: "LM Switcher has received your key — you can close this tab."))
            self.exchange(code: code)
        }
    }

    private func respond(_ conn: NWConnection, html: String) {
        let body = Data(html.utf8)
        var out = Data(("HTTP/1.1 200 OK\r\n" +
                        "Content-Type: text/html; charset=utf-8\r\n" +
                        "Cache-Control: no-store\r\n" +
                        "Connection: close\r\n" +
                        "Content-Length: \(body.count)\r\n\r\n").utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Token exchange

    private func exchange(code: String) {
        guard let url = URL(string: OrcaRouter.tokenURL) else {
            finish(status: "✗ Invalid token endpoint.", ok: false); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
        ])

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, error in
            guard let self else { return }
            if let error {
                self.finish(status: "✗ Key exchange failed: \(error.localizedDescription)", ok: false)
                return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = obj["key"] as? String else {
                switch status {
                case 400: self.finish(status: "✗ Malformed exchange — try again.", ok: false)
                case 403: self.finish(status: "✗ Code rejected (expired or already used) — try again.", ok: false)
                default:  self.finish(status: "✗ Key exchange failed (HTTP \(status)).", ok: false)
                }
                return
            }
            // Compare the granted scope with what we asked for (api).
            if let scope = obj["scope"] as? String, scope != "api" {
                self.finish(status: "✗ Unexpected scope “\(scope)” — refusing the key.", ok: false)
                return
            }
            if OrcaRouter.saveKey(key) {
                self.finish(status: "✓ Signed in — key stored in the Keychain.", ok: true)
            } else {
                self.finish(status: "✗ Could not save the key to the Keychain.", ok: false)
            }
        }.resume()
    }

    // MARK: - Lifecycle helpers

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(status: "✗ Timed out — try again.", ok: false)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)   // codes live 10 min
    }

    private func finish(status: String, ok: Bool) {
        cancel()
        DispatchQueue.main.async { self.onFinish?(status, ok) }
    }

    // MARK: - PKCE + URL helpers (static — unit-testable)

    static func randomBase64URL(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func buildAuthURL(callback: String, challenge: String, state: String) -> URL? {
        var comps = URLComponents(string: OrcaRouter.authURL)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "callback_url", value: callback),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "app_name", value: OrcaRouter.appName),
            URLQueryItem(name: "scope", value: "api"),
        ]
        if !OrcaRouter.referralCode.isEmpty {
            items.append(URLQueryItem(name: "ref", value: OrcaRouter.referralCode))
        }
        if !OrcaRouter.appID.isEmpty {
            items.append(URLQueryItem(name: "app_id", value: OrcaRouter.appID))
        }
        comps?.queryItems = items
        return comps?.url
    }

    static func queryParams(from pathAndQuery: String) -> [String: String] {
        guard let idx = pathAndQuery.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in pathAndQuery[pathAndQuery.index(after: idx)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = String(kv[1]).replacingOccurrences(of: "+", with: " ")
            out[String(kv[0])] = value.removingPercentEncoding ?? value
        }
        return out
    }

    /// Loopback-only listener on a system-assigned port. The OAuth callback
    /// only ever needs to be reachable from this machine.
    static func makeListener() throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                           port: .any)
        params.allowLocalEndpointReuse = true
        return try NWListener(using: params, on: .any)
    }

    static func page(title: String, text: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>
          body{font-family:-apple-system,system-ui,sans-serif;background:#111;color:#eee;
               display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
          div{text-align:center;max-width:430px;padding:24px}
          h1{font-size:20px;font-weight:600;margin:0 0 8px}
          p{opacity:.65;font-size:14px;margin:0}
        </style></head>
        <body><div><h1>\(title)</h1><p>\(text)</p></div></body></html>
        """
    }
}
