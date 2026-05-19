import CryptoKit
import Foundation

// Drop-in replacement for LLMAPITransport — routes OpenAI-format chat completions
// to AWS Bedrock Claude.
//
// Auth priority:
//   1. AWS_BEARER_TOKEN_BEDROCK env var → Bearer token, OpenAI format, gateway URL
//   2. SigV4 via AWS_ACCESS_KEY_ID / ~/.aws/credentials → Bedrock native format
enum BedrockTransport {

    // MARK: - Public API (same signature as LLMAPITransport)

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let env = ProcessInfo.processInfo.environment

        // Fast path: Motive Bedrock gateway token — no SigV4, keep OpenAI format
        if let token = env["AWS_BEARER_TOKEN_BEDROCK"], !token.isEmpty {
            return try await bearerTokenRequest(originalRequest: request, token: token)
        }

        // Slow path: SigV4 with native Bedrock format
        guard let body = request.httpBody,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw BedrockError.invalidRequest("Missing or invalid JSON body") }

        let creds = try loadCredentials()
        let modelId = resolvedModel(from: payload)
        let bedrockBody = try convertToBedrockFormat(payload)
        let bedrockRequest = try signedRequest(body: bedrockBody, modelId: modelId, credentials: creds)

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: bedrockRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BedrockError.invalidResponse("No HTTP response")
        }

        let openAIData = try convertToOpenAIFormat(data: data, statusCode: http.statusCode, modelId: modelId)
        let syntheticResponse = HTTPURLResponse(
            url: request.url ?? bedrockRequest.url!,
            statusCode: http.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (openAIData, syntheticResponse)
    }

    // MARK: - Bearer token path

    // Forwards the request as-is with Bearer token auth.
    // Gateway URL: BEDROCK_GATEWAY_URL env var, or constructed from region + path from original request.
    private static func bearerTokenRequest(originalRequest: URLRequest, token: String) async throws -> (Data, URLResponse) {
        let env = ProcessInfo.processInfo.environment
        let gatewayBase = env["BEDROCK_GATEWAY_URL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://bedrock-runtime.\(region).amazonaws.com/v1"

        // Always use /chat/completions — the original request URL may carry a Groq
        // base path like /openai/v1 that must not be forwarded to the Bedrock gateway.
        guard let url = URL(string: gatewayBase.trimmingCharacters(in: .init(charactersIn: "/")) + "/chat/completions") else {
            throw BedrockError.invalidRequest("Cannot construct gateway URL from \(gatewayBase)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = originalRequest.httpMethod ?? "POST"
        req.httpBody = originalRequest.httpBody
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: req)
    }

    // MARK: - Defaults

    static let defaultModelId = "us.anthropic.claude-3-5-haiku-20241022-v1:0"

    static var region: String {
        UserDefaults.standard.string(forKey: "bedrock_region")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "us-east-1"
    }

    // MARK: - Credentials

    struct Credentials {
        let accessKeyId: String
        let secretAccessKey: String
        let sessionToken: String?
    }

    static func loadCredentials() throws -> Credentials {
        // 1. Environment variables (set by `mtv aws auth`)
        let env = ProcessInfo.processInfo.environment
        if let ak = env["AWS_ACCESS_KEY_ID"], let sk = env["AWS_SECRET_ACCESS_KEY"], !ak.isEmpty {
            return Credentials(accessKeyId: ak, secretAccessKey: sk, sessionToken: env["AWS_SESSION_TOKEN"])
        }

        // 2. ~/.aws/credentials — try profile from setting, then "keeptruckin", then "default"
        let profile = UserDefaults.standard.string(forKey: "bedrock_aws_profile")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "keeptruckin"
        let candidates = [profile, "default"]
        let credsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".aws/credentials")
        guard let content = try? String(contentsOf: credsURL) else {
            throw BedrockError.noCredentials("No AWS credentials found. Run `mtv aws auth` and try again.")
        }

        for profileName in candidates {
            if let creds = parseCredentialsFile(content, profile: profileName) { return creds }
        }
        throw BedrockError.noCredentials("Profile '\(profile)' not found in ~/.aws/credentials. Run `mtv aws auth`.")
    }

    private static func parseCredentialsFile(_ content: String, profile: String) -> Credentials? {
        let header = "[\(profile)]"
        let lines = content.components(separatedBy: .newlines)
        var inSection = false
        var ak: String?, sk: String?, token: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inSection { break }
                inSection = (trimmed == header)
                continue
            }
            guard inSection else { continue }
            let parts = trimmed.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let key = parts[0]; let val = parts[1...].joined(separator: "=")
            switch key {
            case "aws_access_key_id": ak = val
            case "aws_secret_access_key": sk = val
            case "aws_session_token": token = val
            default: break
            }
        }
        guard let ak, let sk, !ak.isEmpty else { return nil }
        return Credentials(accessKeyId: ak, secretAccessKey: sk, sessionToken: token)
    }

    // MARK: - Format conversion

    private static func resolvedModel(from payload: [String: Any]) -> String {
        (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModelId
    }

    private static func convertToBedrockFormat(_ openAIPayload: [String: Any]) throws -> Data {
        let messages = (openAIPayload["messages"] as? [[String: Any]]) ?? []
        var system: String? = nil
        var bedrockMessages: [[String: Any]] = []

        for msg in messages {
            guard let role = msg["role"] as? String else { continue }
            if role == "system" {
                system = msg["content"] as? String
                continue
            }
            let content = convertContent(msg["content"])
            bedrockMessages.append(["role": role, "content": content])
        }

        var body: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": (openAIPayload["max_completion_tokens"] as? Int) ?? (openAIPayload["max_tokens"] as? Int) ?? 4096,
            "messages": bedrockMessages
        ]
        if let system { body["system"] = system }
        if let temp = openAIPayload["temperature"] { body["temperature"] = temp }
        return try JSONSerialization.data(withJSONObject: body)
    }

    // Convert OpenAI content (String or array with image_url) → Bedrock content array
    private static func convertContent(_ raw: Any?) -> Any {
        if let text = raw as? String {
            return [["type": "text", "text": text]]
        }
        guard let parts = raw as? [[String: Any]] else { return [] }
        return parts.compactMap { part -> [String: Any]? in
            guard let type_ = part["type"] as? String else { return nil }
            if type_ == "text", let text = part["text"] as? String {
                return ["type": "text", "text": text]
            }
            if type_ == "image_url", let imgObj = part["image_url"] as? [String: Any],
               let dataURL = imgObj["url"] as? String {
                // "data:image/jpeg;base64,XXX" → Bedrock image block
                let comps = dataURL.components(separatedBy: ",")
                guard comps.count == 2 else { return nil }
                let header = comps[0] // "data:image/jpeg;base64"
                let b64 = comps[1]
                let mediaType = header.components(separatedBy: ":").last?
                    .components(separatedBy: ";").first ?? "image/jpeg"
                return ["type": "image", "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": b64
                ]]
            }
            return nil
        }
    }

    // Convert Bedrock Claude response → OpenAI chat.completion format
    private static func convertToOpenAIFormat(data: Data, statusCode: Int, modelId: String) throws -> Data {
        guard statusCode == 200 else { return data } // pass errors through as-is

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let text = contentArray.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw BedrockError.invalidResponse("Unexpected Bedrock response shape") }

        let openAI: [String: Any] = [
            "id": json["id"] as? String ?? "bedrock-\(UUID().uuidString)",
            "object": "chat.completion",
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": "stop"
            ]],
            "usage": json["usage"] as? [String: Any] ?? [:]
        ]
        return try JSONSerialization.data(withJSONObject: openAI)
    }

    // MARK: - SigV4 signing

    private static func signedRequest(body: Data, modelId: String, credentials: Credentials) throws -> URLRequest {
        let service = "bedrock-runtime"
        let reg = region
        let endpoint = "https://\(service).\(reg).amazonaws.com/model/\(modelId)/invoke"
        guard let url = URL(string: endpoint) else {
            throw BedrockError.invalidRequest("Could not construct Bedrock URL for model \(modelId)")
        }

        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let amzDate = iso8601Compact(now)
        let dateStamp = String(amzDate.prefix(8))

        let bodyHash = sha256Hex(body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        // Canonical request
        let host = url.host!
        var canonicalHeaders = "content-type:application/json\nhost:\(host)\nx-amz-content-sha256:\(bodyHash)\nx-amz-date:\(amzDate)\n"
        var signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        if credentials.sessionToken != nil {
            canonicalHeaders += "x-amz-security-token:\(credentials.sessionToken!)\n"
            signedHeaders += ";x-amz-security-token"
        }
        let canonicalRequest = [
            "POST",
            "/model/\(modelId)/invoke",
            "",
            canonicalHeaders,
            signedHeaders,
            bodyHash
        ].joined(separator: "\n")

        // String to sign
        let credentialScope = "\(dateStamp)/\(reg)/\(service)/aws4_request"
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"

        // Signing key
        let signingKey = deriveSigningKey(secret: credentials.secretAccessKey, date: dateStamp, region: reg, service: service)
        let signature = hmacSHA256Hex(key: signingKey, data: stringToSign)

        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Crypto helpers (CryptoKit)

    private static func iso8601Compact(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      comps.year!, comps.month!, comps.day!,
                      comps.hour!, comps.minute!, comps.second!)
    }

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, data: String) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: symmetricKey)
        return Data(mac)
    }

    private static func hmacSHA256Hex(key: Data, data: String) -> String {
        hmacSHA256(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func deriveSigningKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate    = hmacSHA256(key: Data("AWS4\(secret)".utf8), data: date)
        let kRegion  = hmacSHA256(key: kDate,    data: region)
        let kService = hmacSHA256(key: kRegion,  data: service)
        return        hmacSHA256(key: kService,  data: "aws4_request")
    }
}

enum BedrockError: LocalizedError {
    case noCredentials(String)
    case invalidRequest(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials(let m): return "AWS credentials: \(m)"
        case .invalidRequest(let m): return "Bedrock request error: \(m)"
        case .invalidResponse(let m): return "Bedrock response error: \(m)"
        }
    }
}
