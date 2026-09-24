import Foundation
import LiveIngestionCore

public enum AssistantError: Error, LocalizedError, Sendable {
    case notSignedIn
    case http(Int, String)
    case provider(String)
    case invalidOutput(String)
    case missingSourceText
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return String(localized: "尚未登录助手账号，请先在设置中登录。", bundle: .kit)
        case .http(let status, let body): return String(localized: "助手服务返回错误（状态码 \(status)）：\(body)", bundle: .kit)
        case .provider(let message): return String(localized: "助手服务出错：\(message)", bundle: .kit)
        case .invalidOutput(let message): return String(localized: "无法解析助手返回的内容：\(message)", bundle: .kit)
        case .missingSourceText: return String(localized: "此活动缺少官网原文，无法生成摘要。", bundle: .kit)
        case .cancelled: return String(localized: "已取消。", bundle: .kit)
        }
    }
}

public enum AssistantTransport: Sendable {
    case openAIAPI(apiKey: String)
    case chatGPTBackend(accessToken: String, accountID: String?)

    public var endpoint: URL {
        switch self {
        case .openAIAPI:
            return URL(string: "https://api.openai.com/v1/responses")!
        case .chatGPTBackend:
            return URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        }
    }
}

public struct OpenAIResponsesClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func generateStructured(
        model: String,
        instructions: String,
        input: String,
        schemaName: String,
        schema: [String: Any],
        transport: AssistantTransport
    ) async throws -> String {
        var request = URLRequest(url: transport.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        switch transport {
        case .openAIAPI(let apiKey):
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .chatGPTBackend(let accessToken, let accountID):
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        }

        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": input]
                    ]
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": schema
                ]
            ],
            "store": false,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidOutput("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(2048), encoding: .utf8) ?? ""
            throw AssistantError.http(http.statusCode, snippet)
        }

        return try Self.parseResponse(
            data,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
    }

    public func listModels(transport: AssistantTransport) async throws -> [String] {
        guard case .openAIAPI(let apiKey) = transport else { return [] }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data.prefix(2048), encoding: .utf8) ?? ""
            throw AssistantError.http(status, snippet)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: - Parsing

    /// Parses a Responses API body using both its declared content type and
    /// its actual shape. Some compatible backends return an SSE stream while
    /// incorrectly labeling it as JSON.
    static func parseResponse(_ data: Data, contentType: String?) throws -> String {
        if contentType?.localizedCaseInsensitiveContains("text/event-stream") == true
            || looksLikeEventStream(data) {
            return try parseSSE(data)
        }
        return try parseJSONResponse(data)
    }

    private static func looksLikeEventStream(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let firstLine = normalized.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return false
        }
        let line = firstLine.drop(while: { $0 == " " || $0 == "\t" || $0 == "\u{feff}" })
        return line.hasPrefix("data:")
            || line.hasPrefix("event:")
            || line.hasPrefix("id:")
            || line.hasPrefix("retry:")
            || line.hasPrefix(":")
    }

    private static func parseSSE(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AssistantError.invalidOutput(String(localized: "返回的数据不是有效的文字。", bundle: .kit))
        }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let events = normalized.components(separatedBy: "\n\n")
        var deltaAccumulator = ""
        var completedOutput: String?
        var didComplete = false

        for event in events {
            let lines = event.split(separator: "\n")
            var dataLines: [String] = []
            var eventName: String?
            for line in lines {
                if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    dataLines.append(value)
                } else if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !dataLines.isEmpty else { continue }
            let payload = dataLines.joined(separator: "\n")
            guard payload != "[DONE]" else { continue }
            guard let payloadData = payload.data(using: .utf8) else {
                throw AssistantError.invalidOutput(String(localized: "事件流包含无法读取的数据。", bundle: .kit))
            }
            let value: Any
            do {
                value = try JSONSerialization.jsonObject(with: payloadData)
            } catch {
                throw AssistantError.invalidOutput(String(localized: "事件流中的数据格式不正确。", bundle: .kit))
            }
            guard let json = value as? [String: Any] else {
                throw AssistantError.invalidOutput(String(localized: "事件流中的数据格式不正确。", bundle: .kit))
            }
            guard let type = (json["type"] as? String) ?? eventName else { continue }

            switch type {
            case "response.completed", "response.done":
                let response = (json["response"] as? [String: Any]) ?? json
                try rejectUnsuccessfulResponse(response, envelope: json)
                completedOutput = extractOutputText(from: response)
                didComplete = true
            case "response.output_text.delta":
                if let delta = json["delta"] as? String {
                    deltaAccumulator += delta
                }
            case "response.failed", "response.incomplete", "response.cancelled", "response.canceled":
                let message = errorMessage(from: json)
                    ?? String(localized: "回复未能完成，请重试。", bundle: .kit)
                throw AssistantError.provider(message)
            case "error":
                let message = errorMessage(from: json)
                    ?? String(localized: "服务返回了未知错误。", bundle: .kit)
                throw AssistantError.provider(message)
            default:
                continue
            }
        }

        guard didComplete else {
            throw AssistantError.invalidOutput(String(localized: "回复在完成前中断，请重试。", bundle: .kit))
        }
        if let completedOutput, !completedOutput.isEmpty {
            return completedOutput
        }
        if !deltaAccumulator.isEmpty {
            return deltaAccumulator
        }
        throw AssistantError.invalidOutput(String(localized: "已完成的回复中没有可用内容。", bundle: .kit))
    }

    private static func parseJSONResponse(_ data: Data) throws -> String {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AssistantError.invalidOutput(String(localized: "返回内容格式不正确，请重试。", bundle: .kit))
        }
        guard let json = value as? [String: Any] else {
            throw AssistantError.invalidOutput(String(localized: "返回内容不是有效的对象。", bundle: .kit))
        }
        if let errorObject = json["error"] as? [String: Any] {
            let message = (errorObject["message"] as? String)
                ?? String(localized: "服务返回了未知错误。", bundle: .kit)
            throw AssistantError.provider(message)
        }
        let root = (json["response"] as? [String: Any]) ?? json
        try rejectUnsuccessfulResponse(root, envelope: json)
        if let output = extractOutputText(from: root), !output.isEmpty {
            return output
        }
        throw AssistantError.invalidOutput(String(localized: "回复中没有可用内容。", bundle: .kit))
    }

    private static func rejectUnsuccessfulResponse(
        _ response: [String: Any],
        envelope: [String: Any]
    ) throws {
        guard let status = response["status"] as? String else { return }
        guard status == "completed" else {
            switch status {
            case "failed", "incomplete", "cancelled", "canceled":
                let message = errorMessage(from: envelope)
                    ?? errorMessage(from: response)
                    ?? String(localized: "回复未能完成，请重试。", bundle: .kit)
                throw AssistantError.provider(message)
            case "queued", "in_progress":
                throw AssistantError.invalidOutput(
                    String(localized: "回复尚未完成，请重试。", bundle: .kit)
                )
            default:
                throw AssistantError.invalidOutput(
                    String(localized: "回复状态不正确，请重试。", bundle: .kit)
                )
            }
        }
    }

    private static func extractOutputText(from response: [String: Any]) -> String? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        var text = ""
        for item in output {
            guard item["type"] as? String == "message" else { continue }
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if part["type"] as? String == "output_text", let partText = part["text"] as? String {
                    text += partText
                }
            }
        }
        return text.isEmpty ? nil : text
    }

    private static func errorMessage(from json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let response = json["response"] as? [String: Any], let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let details = json["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            return incompleteMessage(for: reason)
        }
        if let response = json["response"] as? [String: Any],
           let details = response["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String {
            return incompleteMessage(for: reason)
        }
        return json["message"] as? String
    }

    private static func incompleteMessage(for reason: String) -> String {
        switch reason {
        case "max_output_tokens":
            return String(localized: "回复超过长度限制，未能完整生成。", bundle: .kit)
        case "content_filter":
            return String(localized: "回复因内容限制未能完成。", bundle: .kit)
        default:
            return String(localized: "回复未能完成，请重试。", bundle: .kit)
        }
    }
}
