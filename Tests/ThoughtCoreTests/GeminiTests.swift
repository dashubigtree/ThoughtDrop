import Foundation
import Testing
@testable import ThoughtCore

struct GeminiTests {
    @Test func requestKeepsAudioAsDataAndKeyOutOfBody() throws {
        let body = try GeminiTranscriber.requestBody(audio: Data([1, 2, 3]), mimeType: "audio/mp4")
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["systemInstruction"] != nil)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(Data([1, 2, 3]).base64EncodedString()))
    }

    @Test func parsesTranscriptAndRejectsBadResponses() throws {
        let ok = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":" 你好，世界 "}]}}]}"#
        #expect(try GeminiTranscriber.parse(Data(ok.utf8)) == "你好，世界")
        let empty = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":" "}]}}]}"#
        #expect(throws: (any Error).self) { try GeminiTranscriber.parse(Data(empty.utf8)) }
        let cut = #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"半段"}]}}]}"#
        #expect(throws: (any Error).self) { try GeminiTranscriber.parse(Data(cut.utf8)) }
        let blocked = #"{"promptFeedback":{"blockReason":"OTHER"}}"#
        #expect(throws: (any Error).self) { try GeminiTranscriber.parse(Data(blocked.utf8)) }
        #expect(throws: (any Error).self) { try GeminiTranscriber.parse(Data("{}".utf8)) }
    }
}
