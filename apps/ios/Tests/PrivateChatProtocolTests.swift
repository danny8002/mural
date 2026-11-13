import XCTest
@testable import MuralCore

final class PrivateChatProtocolTests: XCTestCase {
    func testCredentialsCanOnlyTargetPrivateConversationEndpoints() throws {
        for path in ["/v1/capabilities", "/v1/live/sessions", "/v1/responses", "/v1/live/close"] {
            let url = try PrivateChatProtocol.endpoint(path)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "mural-simple-chat-service.onrender.com")
            XCTAssertEqual(url.path, path)
            XCTAssertNil(url.query)
        }
        for path in ["/v1/account", "/v1/wallet", "/v1/auth/exchange", "/v1/checkout",
                     "https://api.openai.com/v1/responses", "//attacker.test/v1/responses",
                     "/v1/responses?key=secret", "/v1/../responses"] {
            XCTAssertThrowsError(try PrivateChatProtocol.endpoint(path), path)
        }
    }

    func testPrivateAPIKEYDoesNotRequireOpenAIKeyPrefixAndRejectsWhitespace() {
        XCTAssertTrue(PrivateChatProtocol.validKey(String(repeating: "a", count: 32)))
        XCTAssertTrue(PrivateChatProtocol.validKey(String(repeating: "b", count: 512)))
        for key in ["", "sk-short", String(repeating: "x", count: 513),
                    String(repeating: "a", count: 31), String(repeating: "a", count: 32) + "\n",
                    String(repeating: "a", count: 32) + " ", String(repeating: "a", count: 32) + "\u{00E9}"] {
            XCTAssertFalse(PrivateChatProtocol.validKey(key))
        }
    }

    func testVoiceBodyMatchesPrivateServiceWithoutHostedFundingOrProviderCredentials() throws {
        let id = UUID()
        let history: [[String: Any]] = [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Hola"]]]
        ]
        let body = try PrivateChatProtocol.voiceBody(sdp: "v=0\r\noffer", language: "es-ES",
                                                      instructions: "Speak Spanish.", history: history, requestID: id)
        XCTAssertEqual(Set(body.keys), ["requestID", "sdp", "language", "instructions", "history"])
        XCTAssertEqual(body["requestID"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(body["language"] as? String, "es-ES")
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: XCTUnwrap(body["history"]), options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: history, options: .sortedKeys))
        XCTAssertThrowsError(try PrivateChatProtocol.voiceBody(sdp: "invalid", language: "es-ES", instructions: "Speak.", history: []))
        XCTAssertThrowsError(try PrivateChatProtocol.voiceBody(sdp: "v=0", language: "es-ES", instructions: String(repeating: "x", count: 12_001), history: []))
    }

    func testHelpersUsePrivateSchemaAndStreamContractInsteadOfOpenAIPayload() throws {
        let schema: [String: Any] = ["type": "object", "properties": [:], "required": [], "additionalProperties": false]
        let id = UUID()
        let body = PrivateChatProtocol.helperBody(instructions: "Assess.", input: "Hola", purpose: "assessment",
                                                   schema: schema, search: false, stream: true, requestID: id)
        XCTAssertEqual(Set(body.keys), ["requestID", "purpose", "instructions", "input", "schema", "search", "stream"])
        XCTAssertEqual(body["input"] as? String, "Hola")
        XCTAssertEqual(body["requestID"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["model"])
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["APIKEY"])
        XCTAssertNil(body["SESSION_SIGNING_SECRET"])
    }

    func testCapabilitiesRejectOtherProtocolVersionsAndMissingSupport() throws {
        let valid: [String: Any] = ["protocolVersion": 1, "voice": true, "helpers": true, "webSearch": false]
        XCTAssertFalse(try PrivateChatCapabilities(valid).webSearch)
        for change: [String: Any] in [
            ["protocolVersion": 2], ["voice": false], ["helpers": false], ["webSearch": "true"]
        ] {
            XCTAssertThrowsError(try PrivateChatCapabilities(valid.merging(change) { _, new in new }))
        }
    }

    func testLeaseRequiresWebRTCAnswerAndOpaqueSignedCloseHandle() throws {
        let valid: [String: Any] = [
            "session": ["id": "sess_private"],
            "transport": ["type": "webrtc", "sdp": "v=0\r\nanswer"],
            "closeHandle": "payload.signature"
        ]
        let lease = try PrivateChatLease(valid)
        XCTAssertEqual(lease.providerID, "sess_private")
        XCTAssertEqual(lease.answerSDP, "v=0\r\nanswer")
        XCTAssertEqual(lease.closeHandle, "payload.signature")
        for change: [String: Any] in [
            ["session": ["id": "../other"]],
            ["transport": ["type": "websocket", "sdp": "v=0"]],
            ["transport": ["type": "webrtc", "sdp": "invalid"]],
            ["closeHandle": ""], ["closeHandle": "https://attacker.test"]
        ] {
            XCTAssertThrowsError(try PrivateChatLease(valid.merging(change) { _, new in new }))
        }
    }

    func testPrivateErrorsDoNotExposeProviderBodiesOrReferToMuralPurchases() {
        let error = PrivateChatProtocol.serverError(status: 401, body: Data(#"{"error":{"code":"unauthorized","message":"secret"}}"#.utf8))
        XCTAssertTrue(error.localizedDescription.contains("APIKEY"))
        XCTAssertFalse(error.localizedDescription.contains("secret"))
        let search = PrivateChatProtocol.serverError(status: 422, body: Data(#"{"error":{"code":"search_unavailable"}}"#.utf8))
        XCTAssertTrue(search.localizedDescription.contains("Web search"))
        XCTAssertFalse(search.localizedDescription.contains("OpenAI key"))
    }
}
