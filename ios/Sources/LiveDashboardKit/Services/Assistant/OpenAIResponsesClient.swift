import Foundation

public enum AssistantError: Error, LocalizedError, Sendable {
    case notSignedIn
    case http(Int, String)
    case provider(String)
    case invalidOutput(String)
    case missingSourceText
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return "尚未登录助手账号，请先在设置中登录。"
        case .http(let status, let body): return "助手服务返回错误（状态码 \(status)）：\(body)"
        case .provider(let message): return "助手服务出错：\(message)"
        case .invalidOutput(let message): return "无法解析助手返回的内容：\(message)"
        case .missingSourceText: return "此活动缺少官网原文，无法生成摘要。"
        case .cancelled: return "已取消。"
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

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            return try Self.parseSSE(data)
        }
        return try Self.parseJSONResponse(data)
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

    private static func parseSSE(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AssistantError.invalidOutput("non-UTF8 stream")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let events = normalized.components(separatedBy: "\n\n")
        var deltaAccumulator = ""
        var completedOutput: String?

        for event in events {
            let lines = event.split(separator: "\n")
            var dataLines: [String] = []
            for line in lines {
                if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") { value.removeFirst() }
                    dataLines.append(value)
                }
            }
            guard !dataLines.isEmpty else { continue }
            let payload = dataLines.joined(separator: "\n")
            guard payload != "[DONE]" else { continue }
            guard let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { continue }
            guard let type = json["type"] as? String else { continue }

            switch type {
            case "response.completed", "response.done":
                if let response = json["response"] as? [String: Any] {
                    completedOutput = extractOutputText(from: response)
                }
            case "response.output_text.delta":
                if let delta = json["delta"] as? String {
                    deltaAccumulator += delta
                }
            case "response.failed":
                let message = errorMessage(from: json) ?? "response.failed"
                throw AssistantError.provider(message)
            case "error":
                let message = errorMessage(from: json) ?? "unknown error"
                throw AssistantError.provider(message)
            default:
                continue
            }
        }

        if let completedOutput, !completedOutput.isEmpty {
            return completedOutput
        }
        if !deltaAccumulator.isEmpty {
            return deltaAccumulator
        }
        throw AssistantError.invalidOutput("no output in event stream")
    }

    private static func parseJSONResponse(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.invalidOutput("response is not a JSON object")
        }
        if let errorObject = json["error"] as? [String: Any] {
            let message = (errorObject["message"] as? String) ?? "unknown error"
            throw AssistantError.provider(message)
        }
        let root = (json["response"] as? [String: Any]) ?? json
        if let output = extractOutputText(from: root), !output.isEmpty {
            return output
        }
        throw AssistantError.invalidOutput("no output in response")
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
        return json["message"] as? String
    }
}
