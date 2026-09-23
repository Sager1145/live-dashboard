import Foundation
import XCTest
@testable import LiveDashboardKit

final class ResponsesParsingTests: XCTestCase {
    func testParsesEventStreamWhenContentTypeIncorrectlyClaimsJSON() throws {
        let expected = #"{"overview":"测试摘要"}"#
        let body = try Self.eventStream([
            [
                "type": "response.output_text.delta",
                "delta": expected
            ],
            [
                "type": "response.completed",
                "response": ["status": "completed"]
            ]
        ])

        let output = try OpenAIResponsesClient.parseResponse(
            body,
            contentType: "application/json; charset=utf-8"
        )

        XCTAssertEqual(output, expected)
    }

    func testRejectsEventStreamThatEndsAfterOnlyDeltas() throws {
        let body = try Self.eventStream([
            [
                "type": "response.output_text.delta",
                "delta": #"{"partial":true}"#
            ]
        ])

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(body, contentType: "text/event-stream")
        ) { error in
            guard case AssistantError.invalidOutput(let message) = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
            XCTAssertEqual(
                message,
                String(localized: "回复在完成前中断，请重试。", bundle: .kit)
            )
        }
    }

    func testRejectsFailedCompletionEvenWhenItContainsOutput() throws {
        let body = try Self.eventStream([
            [
                "type": "response.completed",
                "response": [
                    "status": "failed",
                    "error": ["message": "模型暂时不可用"],
                    "output": [
                        [
                            "type": "message",
                            "content": [
                                ["type": "output_text", "text": #"{"shouldNot":"escape"}"#]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(body, contentType: "text/event-stream")
        ) { error in
            guard case AssistantError.provider(let message) = error else {
                return XCTFail("expected provider error, got \(error)")
            }
            XCTAssertEqual(message, "模型暂时不可用")
        }
    }

    func testRejectsIncompleteJSONResponseWithReadableError() throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "status": "incomplete",
            "incomplete_details": ["reason": "max_output_tokens"],
            "output": [
                [
                    "type": "message",
                    "content": [
                        ["type": "output_text", "text": #"{"partial":true}"#]
                    ]
                ]
            ]
        ])

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(body, contentType: "application/json")
        ) { error in
            guard case AssistantError.provider(let message) = error else {
                return XCTFail("expected provider error, got \(error)")
            }
            XCTAssertEqual(
                message,
                String(localized: "回复超过长度限制，未能完整生成。", bundle: .kit)
            )
            XCTAssertFalse(message.contains("max_output_tokens"))
        }
    }

    func testRejectsCompletedEventWhoseResponseIsStillInProgress() throws {
        let body = try Self.eventStream([
            [
                "type": "response.completed",
                "response": [
                    "status": "in_progress",
                    "output": [
                        [
                            "type": "message",
                            "content": [
                                ["type": "output_text", "text": #"{"partial":true}"#]
                            ]
                        ]
                    ]
                ]
            ]
        ])

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(body, contentType: "text/event-stream")
        ) { error in
            guard case AssistantError.invalidOutput(let message) = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
            XCTAssertEqual(
                message,
                String(localized: "回复尚未完成，请重试。", bundle: .kit)
            )
        }
    }

    func testMalformedJSONDoesNotExposeFoundationSerializationError() {
        let body = Data(#"{"unfinished":"#.utf8)

        XCTAssertThrowsError(
            try OpenAIResponsesClient.parseResponse(body, contentType: "application/json")
        ) { error in
            guard case AssistantError.invalidOutput(let message) = error else {
                return XCTFail("expected invalidOutput, got \(error)")
            }
            XCTAssertEqual(
                message,
                String(localized: "返回内容格式不正确，请重试。", bundle: .kit)
            )
            XCTAssertFalse(error.localizedDescription.contains("NSCocoaErrorDomain"))
            XCTAssertFalse(error.localizedDescription.contains("3840"))
        }
    }

    private static func eventStream(_ events: [[String: Any]]) throws -> Data {
        let text = try events.map { event in
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }.joined()
        return Data(text.utf8)
    }
}
