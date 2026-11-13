import Foundation
import Security
import UIKit
import MuralCore

enum PrivateChatCredentialStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "chat.mural.private-server",
         kSecAttrAccount as String: PrivateChatProtocol.origin.absoluteString,
         kSecAttrSynchronizable as String: false]
    }
    static func read() -> String? {
        var itemQuery = query
        itemQuery[kSecReturnData as String] = true; itemQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(itemQuery as CFDictionary, &item) == errSecSuccess, let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static var hasKey: Bool { read() != nil }
    static func save(_ value: String) throws {
        guard PrivateChatProtocol.validKey(value) else { throw PrivateChatError.invalidKey }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var itemQuery = query; itemQuery[kSecValueData as String] = data
            itemQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(itemQuery as CFDictionary, nil) == errSecSuccess else { throw PrivateChatError.secureStorage }
        } else if status != errSecSuccess { throw PrivateChatError.secureStorage }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PrivateChatError.secureStorage }
    }
}

@MainActor final class PrivateChatClient {
    private let session: URLSession
    private var credential = VoiceCredentialScope()
    private var credentialExpiry: Task<Void, Never>?
    private(set) var capabilities: PrivateChatCapabilities?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    func beginConversation() {
        clearCredential()
        guard let key = PrivateChatCredentialStore.read() else { return }
        credential.begin(key: key)
        expireCredential(after: .seconds(65 * 60))
    }
    func endConversation() {
        credential.end()
        expireCredential(after: .seconds(60))
    }
    func clearCredential() {
        credentialExpiry?.cancel(); credentialExpiry = nil
        credential.clear(); capabilities = nil
    }
    private func expireCredential(after duration: Duration) {
        credentialExpiry?.cancel()
        credentialExpiry = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            self?.credential.clear(); self?.credentialExpiry = nil
        }
    }
    private func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let key = credential.credential(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable,
                                               readStored: PrivateChatCredentialStore.read)
        else { throw PrivateChatError.missingKey }
        var request = URLRequest(url: try PrivateChatProtocol.endpoint(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrivateChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PrivateChatProtocol.serverError(status: http.statusCode, body: data)
        }
        guard data.count <= 1_048_576,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw PrivateChatError.invalidResponse }
        return value
    }
    func loadCapabilities() async throws {
        capabilities = try PrivateChatCapabilities(await send(request("/v1/capabilities")))
    }
    func create(sdp: String, language: String, instructions: String, history: [[String: Any]]) async throws -> PrivateChatLease {
        let body = try PrivateChatProtocol.voiceBody(sdp: sdp, language: language, instructions: instructions, history: history)
        return try PrivateChatLease(await send(request("/v1/live/sessions", body: body)))
    }
    func respond(instructions: String, input: String, purpose: String, schema: [String: Any]?,
                 search: Bool, onText: (@MainActor (String) -> Void)?) async throws -> [String: Any] {
        if search {
            if capabilities == nil { try await loadCapabilities() }
            guard capabilities?.webSearch == true else { throw PrivateChatError.searchUnavailable }
        }
        let body = PrivateChatProtocol.helperBody(instructions: instructions, input: input, purpose: purpose,
                                                  schema: schema, search: search, stream: onText != nil)
        var request = try request("/v1/responses", body: body)
        guard let onText else { return try await send(request) }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrivateChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count >= 16_384 { break } }
            throw PrivateChatProtocol.serverError(status: http.statusCode, body: data)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true
        else { throw PrivateChatError.invalidResponse }
        var decoder = ResponseTextStream()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                switch try decoder.consume(byte: byte) {
                case .text(let value): onText(value)
                case .completed(let value): return value
                case nil: break
                }
            }
        } catch ResponseTextStream.Failure.refused { throw APIClient.APIError.refused }
        catch is ResponseTextStream.Failure { throw PrivateChatError.invalidResponse }
        throw PrivateChatError.invalidResponse
    }
    func close(_ lease: PrivateChatLease, completion: @escaping @MainActor (String?) -> Void) {
        let closeRequest: URLRequest
        do { closeRequest = try request("/v1/live/close", body: ["closeHandle": lease.closeHandle]) }
        catch { completion(error.localizedDescription); return }
        Task {
            do {
                let result = try await send(closeRequest)
                guard result["status"] as? String == "confirmed" else {
                    completion(PrivateChatError.closeUnconfirmed.localizedDescription); return
                }
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }
}
