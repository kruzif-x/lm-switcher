// -----------------------------------------------------------------------------
//  OrcaRouter — optional cloud provider support (LM Switcher).
//
//  OrcaRouter (orcarouter.ai) is an OpenAI-compatible gateway to 200+ cloud
//  models (DeepSeek, GLM, Kimi, …) billed at provider rates with no markup.
//  It is OPTIONAL and additive: nothing here touches local engine
//  discovery, launching, or the menu — this file only provides
//
//    1. Keychain storage for the API key (the key is a secret and must
//       never be written to UserDefaults or any settings file), and
//    2. a `GET <base>/models` connection test used by the OrcaRouter
//       Settings tab.
//
//  Created 2026-09-30. Referral link: sign-ups via the app's referral link
//  support development (OrcaRouter pays the flagship 5% of referred
//  workspaces' eligible inference spend).
// -----------------------------------------------------------------------------

import Foundation
import Security

enum OrcaRouter {

    /// Default base URL of the OrcaRouter OpenAI-compatible API.
    static let defaultBaseURL = "https://api.orcarouter.ai/v1"

    /// Referral link shown in the OrcaRouter tab / About / README.
    static let referralURL = "https://www.orcarouter.ai/ref/ref_a1a2c3f77b1a87bde5f8"

    /// OAuth 2.0 + PKCE endpoints for "Sign in with OrcaRouter"
    /// (docs.orcarouter.ai/getting-started/sign-in-with-orcarouter).
    static let authURL  = "https://www.orcarouter.ai/auth"
    static let tokenURL = "https://www.orcarouter.ai/api/v1/auth/keys"

    /// App name shown on the consent screen.
    static let appName = "LM Switcher"

    /// Partner app id — issued by OrcaRouter on the partner console's
    /// Integration page once the listing is approved. Empty is fine: the
    /// flow still works; the consent screen just shows an unverified name
    /// and keys aren't tagged "via your app". Set this to turn on the
    /// Verified badge + usage attribution.
    static let appID = ""

    /// Referral code sent with sign-ins (credits sign-ups to the listing).
    static let referralCode = "ref_a1a2c3f77b1a87bde5f8"

    /// Keychain coordinates. Service is stable across versions so the
    /// stored key survives app updates.
    static let keychainService = "local.llama-menubar.orcarouter"
    static let keychainAccount = "api-key"

    // MARK: - Keychain

    /// Store (or replace) the API key in the macOS Keychain.
    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        // Replace semantics: clear any previous value first.
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored API key, or nil when none is set.
    static func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the stored API key. Succeeds when the item is already gone.
    @discardableResult
    static func deleteKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Connection test

    struct ConnectionResult {
        var ok: Bool
        var message: String
        /// Live catalog ids from a successful fetch (empty otherwise).
        /// Used to fill the Settings "Default model" picker.
        var modelIDs: [String] = []
    }

    /// GET `<base>/models` with Bearer auth. Verifies the key and returns
    /// the live catalog size. Never logs the key.
    static func testConnection(baseURL: String, apiKey: String) async -> ConnectionResult {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.isEmpty { base = defaultBaseURL }

        guard let url = URL(string: base + "/models") else {
            return ConnectionResult(ok: false, message: "✗ Invalid base URL.")
        }
        guard !apiKey.isEmpty else {
            return ConnectionResult(ok: false, message: "✗ No API key — paste one above and Save first.")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return ConnectionResult(ok: false, message: "✗ No HTTP response.")
            }
            switch http.statusCode {
            case 200:
                struct ModelsResponse: Decodable {
                    struct M: Decodable { let id: String }
                    let data: [M]
                }
                if let m = try? JSONDecoder().decode(ModelsResponse.self, from: data) {
                    let ids = m.data.map { $0.id }
                    let sample = ids.prefix(3).joined(separator: ", ")
                    return ConnectionResult(ok: true,
                        message: "✓ Connected — \(ids.count) models (e.g. \(sample))",
                        modelIDs: ids)
                }
                return ConnectionResult(ok: true, message: "✓ Connected (HTTP 200).")
            case 401, 403:
                return ConnectionResult(ok: false, message: "✗ Key rejected (HTTP \(http.statusCode)) — check the API key.")
            default:
                return ConnectionResult(ok: false, message: "✗ HTTP \(http.statusCode) from \(base)/models.")
            }
        } catch {
            return ConnectionResult(ok: false, message: "✗ \(error.localizedDescription)")
        }
    }
}
