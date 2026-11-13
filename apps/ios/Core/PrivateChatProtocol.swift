import Foundation

public enum PrivateChatError: LocalizedError, Equatable, Sendable {
    case missingKey, invalidKey, secureStorage, invalidResponse, searchUnavailable, closeUnconfirmed
    case server(String, Int)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add the private server APIKEY in Settings > Advanced > Private server APIKEY."
        case .invalidKey: "Enter the private server APIKEY: 32 to 512 characters with no spaces. Do not enter an Azure key or SESSION_SIGNING_SECRET."
        case .secureStorage: "The private server key could not be accessed. Unlock this iPhone and try again."
        case .invalidResponse: "The private server returned an invalid or incomplete response."
        case .searchUnavailable: "Web search is not enabled on the private server. Choose a regular conversation topic."
        case .closeUnconfirmed: "Conversation saved. The private server could not confirm voice closure."
        case .server(_, 401): "The private server did not accept APIKEY. Check Settings > Advanced > Private server APIKEY."
        case .server("search_unavailable", _): "Web search is not enabled on the private server. Choose a regular conversation topic."
        case .server("provider_create_uncertain", _): "Voice startup is unconfirmed. The server will not automatically retry a potentially billed call."
        case .server("duplicate_request", _): "This request was already attempted. No automatic retry was made."
        case .server(_, 429): "The private server is busy or its request limit was reached. Try again shortly."
        case .server(_, let status): "The private server could not complete the request (HTTP \(status)). Check the server configuration."
        }
    }
}

public enum PrivateChatProtocol {
    public static let origin = URL(string: "https://mural-simple-chat-service.onrender.com")!

    public static func endpoint(_ path: String) throws -> URL {
        guard ["/v1/capabilities", "/v1/live/sessions", "/v1/responses", "/v1/live/close"].contains(path)
        else { throw PrivateChatError.invalidResponse }
        return origin.appendingPathComponent(String(path.dropFirst()))
    }

    public static func validKey(_ value: String) -> Bool {
        (32...512).contains(value.utf8.count) &&
            value.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }

    public static func voiceBody(sdp: String, language: String, instructions: String,
                                 history: [[String: Any]], requestID: UUID = UUID()) throws -> [String: Any] {
        guard sdp.hasPrefix("v=0"), sdp.utf8.count <= 65_536,
              !instructions.isEmpty, instructions.utf8.count <= 12_000,
              history.count <= 40, (try JSONSerialization.data(withJSONObject: history)).count <= 6_000
        else { throw PrivateChatError.invalidResponse }
        return ["requestID": requestID.uuidString.lowercased(), "sdp": sdp, "language": language,
                "instructions": instructions, "history": history]
    }

    public static func helperBody(instructions: String, input: String, purpose: String,
                                  schema: [String: Any]? = nil, search: Bool = false,
                                  stream: Bool = false, requestID: UUID = UUID()) -> [String: Any] {
        var body: [String: Any] = ["requestID": requestID.uuidString.lowercased(), "purpose": purpose,
                                  "instructions": instructions, "input": input, "search": search, "stream": stream]
        if let schema { body["schema"] = schema }
        return body
    }

    public static func serverError(status: Int, body: Data) -> PrivateChatError {
        let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let code = (value?["error"] as? [String: Any])?["code"] as? String ?? ""
        let allowed = ["search_unavailable", "provider_create_uncertain", "duplicate_request"]
        return .server(allowed.contains(code) ? code : "request_failed", status)
    }
}

public struct PrivateChatCapabilities: Sendable {
    public let webSearch: Bool
    public init(_ value: [String: Any]) throws {
        guard value["protocolVersion"] as? Int == 1, value["voice"] as? Bool == true,
              value["helpers"] as? Bool == true, let search = value["webSearch"] as? Bool
        else { throw PrivateChatError.invalidResponse }
        webSearch = search
    }
}

public struct PrivateChatLease: Sendable {
    public let providerID: String
    public let answerSDP: String
    public let closeHandle: String

    public init(_ value: [String: Any]) throws {
        guard let session = value["session"] as? [String: Any],
              let id = session["id"] as? String, id.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil,
              let transport = value["transport"] as? [String: Any], transport["type"] as? String == "webrtc",
              let sdp = transport["sdp"] as? String, sdp.hasPrefix("v=0"), sdp.utf8.count <= 65_536,
              let handle = value["closeHandle"] as? String, handle.utf8.count <= 2048,
              handle.range(of: "^[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { throw PrivateChatError.invalidResponse }
        providerID = id; answerSDP = sdp; closeHandle = handle
    }
}
