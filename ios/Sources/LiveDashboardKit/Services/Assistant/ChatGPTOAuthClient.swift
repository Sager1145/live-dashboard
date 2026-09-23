import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum ChatGPTOAuthError: Error, LocalizedError, Sendable, Equatable {
    case stateMismatch
    case missingCode
    case providerError(String)
    case callbackServerUnavailable
    case cancelled
    case invalidResponse
    case invalidGrant

    public var errorDescription: String? {
        switch self {
        case .stateMismatch: return "登录状态校验失败，请重试。"
        case .missingCode: return "未收到登录授权码，请重试。"
        case .providerError(let message): return "登录失败：\(message)"
        case .callbackServerUnavailable: return "本地回调服务器无法启动，请检查端口占用。"
        case .cancelled: return "已取消登录。"
        case .invalidResponse: return "登录服务返回了无法解析的响应。"
        case .invalidGrant: return "ChatGPT 登录已失效，请重新登录"
        }
    }
}

public enum ChatGPTOAuthFailureKind: Sendable {
    case invalidGrant
    case other
}

public struct ChatGPTOAuthConfiguration: Sendable {
    public var authorizeURL: URL
    public var tokenURL: URL
    public var clientID: String
    public var redirectURI: String
    public var scopes: [String]
    public var extraAuthorizeParameters: [String: String]

    public init(
        authorizeURL: URL = URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL = URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann",
        redirectURI: String = "http://localhost:1455/auth/callback",
        scopes: [String] = ["openid", "profile", "email", "offline_access"],
        extraAuthorizeParameters: [String: String] = [
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true"
        ]
    ) {
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraAuthorizeParameters = extraAuthorizeParameters
    }

    public static let `default` = ChatGPTOAuthConfiguration()

    private static let clientIDDefaultsKey = "assistant.oauthClientID"
    private static let redirectURIDefaultsKey = "assistant.oauthRedirectURI"

    /// Reads user-overridable clientID/redirectURI from `UserDefaults`,
    /// falling back to the built-in defaults.
    public static func stored() -> ChatGPTOAuthConfiguration {
        var configuration = ChatGPTOAuthConfiguration.default
        if let clientID = UserDefaults.standard.string(forKey: clientIDDefaultsKey), !clientID.isEmpty {
            configuration.clientID = clientID
        }
        if let redirectURI = UserDefaults.standard.string(forKey: redirectURIDefaultsKey), !redirectURI.isEmpty {
            configuration.redirectURI = redirectURI
        }
        return configuration
    }
}

public struct ChatGPTOAuthClient: Sendable {
    private let configuration: ChatGPTOAuthConfiguration

    public init(configuration: ChatGPTOAuthConfiguration) {
        self.configuration = configuration
    }

    public func authorizationURL(pkce: PKCE) -> URL {
        var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state)
        ]
        for (key, value) in configuration.extraAuthorizeParameters {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url!
    }

    public static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw ChatGPTOAuthError.providerError(error)
        }
        let state = items.first(where: { $0.name == "state" })?.value
        guard state == expectedState else {
            throw ChatGPTOAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw ChatGPTOAuthError.missingCode
        }
        return code
    }

    public func exchangeCode(_ code: String, pkce: PKCE, session: URLSession) async throws -> ChatGPTSession {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI,
            "client_id": configuration.clientID,
            "code_verifier": pkce.verifier
        ]
        request.httpBody = Self.formEncode(form)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ChatGPTOAuthError.providerError("token endpoint returned status \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw ChatGPTOAuthError.invalidResponse
        }
        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        var expiresAt: Date?
        if let expiresIn = json["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(expiresIn)
        } else if let expiresIn = json["expires_in"] as? Int {
            expiresAt = Date().addingTimeInterval(Double(expiresIn))
        }

        var email: String?
        var accountID: String?
        if let idToken, let claims = Self.decodeJWTPayload(idToken) {
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                accountID = auth["chatgpt_account_id"] as? String
            }
            if let profile = claims["https://api.openai.com/profile"] as? [String: Any] {
                email = profile["email"] as? String
            }
            if email == nil {
                email = claims["email"] as? String
            }
        }

        var apiKey: String?
        if let idToken {
            apiKey = try? await exchangeForAPIKey(idToken: idToken, session: session)
        }

        return ChatGPTSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            accountID: accountID,
            email: email,
            apiKey: apiKey
        )
    }

    private func exchangeForAPIKey(idToken: String, session: URLSession) async throws -> String {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [String: String] = [
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "client_id": configuration.clientID,
            "requested_token": "openai-api-key",
            "subject_token": idToken,
            "subject_token_type": "urn:ietf:params:oauth:token-type:id_token"
        ]
        request.httpBody = Self.formEncode(form)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatGPTOAuthError.invalidResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = json["access_token"] as? String else {
            throw ChatGPTOAuthError.invalidResponse
        }
        return apiKey
    }

    public func refresh(_ session: ChatGPTSession, session urlSession: URLSession) async throws -> ChatGPTSession {
        guard let refreshToken = session.refreshToken else {
            throw ChatGPTOAuthError.invalidResponse
        }
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID
        ]
        request.httpBody = Self.formEncode(form)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if status == 401 || ((status == 400) && bodyText.contains("invalid_grant")) {
                throw ChatGPTOAuthError.invalidGrant
            }
            throw ChatGPTOAuthError.providerError("token endpoint returned status \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw ChatGPTOAuthError.invalidResponse
        }
        let newRefreshToken = json["refresh_token"] as? String ?? session.refreshToken
        let idToken = json["id_token"] as? String ?? session.idToken
        var expiresAt = session.expiresAt
        if let expiresIn = json["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(expiresIn)
        } else if let expiresIn = json["expires_in"] as? Int {
            expiresAt = Date().addingTimeInterval(Double(expiresIn))
        }
        return ChatGPTSession(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            accountID: session.accountID,
            email: session.email,
            apiKey: session.apiKey
        )
    }

    /// Decodes the (unverified) payload of a JWT. Used only to read display
    /// claims (email, account id) out of an id_token issued by a trusted
    /// endpoint we just talked to over TLS; never used for authorization.
    public static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(segments[1])) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    private static func formEncode(_ form: [String: String]) -> Data {
        let pairs = form.map { key, value -> String in
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

/// Resumes a continuation at most once, from any thread.
private final class OnceResumer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private let onResume: @Sendable () -> Void

    init(continuation: CheckedContinuation<Value, Error>, onResume: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onResume = onResume
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        onResume()
        pending.resume(with: result)
    }
}

#if canImport(AuthenticationServices) && canImport(UIKit)
@MainActor
public final class ChatGPTSignInFlow: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webAuthSession: ASWebAuthenticationSession?

    public override init() {
        super.init()
    }

    public func signIn(configuration: ChatGPTOAuthConfiguration, urlSession: URLSession = .shared) async throws -> ChatGPTSession {
        let pkce = PKCE()
        let client = ChatGPTOAuthClient(configuration: configuration)
        let authURL = client.authorizationURL(pkce: pkce)

        let redirectScheme = URL(string: configuration.redirectURI)?.scheme
        let useLocalServer = redirectScheme == "http" || redirectScheme == "https"
        let localPort = Self.callbackPort(for: configuration.redirectURI)

        var server: LocalOAuthCallbackServer?
        if useLocalServer {
            let localServer = LocalOAuthCallbackServer(port: localPort)
            server = localServer
        }

        defer {
            server?.onCallback = nil
            server?.onFailure = nil
        }

        let code = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let gate = OnceResumer(continuation: continuation, onResume: { [server] in server?.stop() })
            let resumeOnce: @Sendable (Result<String, Error>) -> Void = { gate.resume($0) }

            if let server {
                server.onCallback = { url in
                    Task { @MainActor in
                        do {
                            let code = try ChatGPTOAuthClient.parseCallback(url, expectedState: pkce.state)
                            resumeOnce(.success(code))
                        } catch {
                            resumeOnce(.failure(error))
                        }
                        self.webAuthSession?.cancel()
                    }
                }
                server.onFailure = { error in
                    resumeOnce(.failure(error))
                }
                do {
                    try server.start()
                } catch {
                    resumeOnce(.failure(error))
                    return
                }
            }

            let session = ASWebAuthenticationSession(url: authURL, callback: .customScheme("live-dashboard")) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    resumeOnce(.failure(ChatGPTOAuthError.cancelled))
                    return
                }
                if let error {
                    resumeOnce(.failure(error))
                    return
                }
                guard let callbackURL else {
                    resumeOnce(.failure(ChatGPTOAuthError.missingCode))
                    return
                }
                do {
                    let code = try ChatGPTOAuthClient.parseCallback(callbackURL, expectedState: pkce.state)
                    resumeOnce(.success(code))
                } catch {
                    resumeOnce(.failure(error))
                }
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.webAuthSession = session
            session.start()
        }

        return try await client.exchangeCode(code, pkce: pkce, session: urlSession)
    }

    /// Parses the local callback server port out of `redirectURI`, falling
    /// back to 1455 when absent or out of `UInt16` range.
    public static func callbackPort(for redirectURI: String) -> UInt16 {
        URL(string: redirectURI)?.port.flatMap { UInt16(exactly: $0) } ?? 1455
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                if let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first {
                    return window
                }
            }
        }
        return ASPresentationAnchor()
    }
}
#endif
