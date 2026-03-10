//
//  ApproovWebViewBridge.swift
//  WebViewShapes
//
//  This file is the reusable core of the quickstart.
//
//  Production goal:
//  - protect the request mechanisms that real WebView apps commonly use for
//    app data exchange: Fetch, XMLHttpRequest, and HTML form submission.
//  - keep Approov token acquisition, cookie handling, and native-only header
//    injection in one place that can be copied to another app.
//
//  Important platform boundary:
//  - public WKWebView APIs do not let an app mutate headers on WebKit's own
//    arbitrary built-in `https://` subresource pipeline before requests leave
//    the networking process.
//  - because of that, this bridge installs a document-start JavaScript shim
//    that forwards Fetch, XHR, and current-frame form submissions into native
//    Swift, where Approov can add a JWT and any native-only headers.
//  - if a form submission is meant to navigate the current frame, the native
//    response is pushed back into WKWebView using `loadSimulatedRequest(...)`
//    so the resulting page still loads in the WebView under the expected URL.
//
//  Reuse guidance:
//  - copy this file into another app.
//  - create your own `ApproovWebViewConfiguration`.
//  - decide which URLs should attempt Approov protection.
//  - use `mutateRequest` for native-only headers such as API keys.
//  - keep API traffic on Fetch, XHR, or current-frame form submits if you want
//    this bridge to mediate it.
//

import ApproovURLSession
import Foundation
import OSLog
import SwiftUI
import UIKit
import WebKit

/// Describes the first content loaded into the protected WebView.
///
/// `.request` is appropriate when the app opens a hosted web experience.
/// `.htmlString` is useful for local demos or bundled HTML.
enum ApproovWebViewContent {
    case htmlString(String, baseURL: URL?)
    case request(URLRequest)
}

/// Holds the generic policy for an Approov-protected WebView.
///
/// This type is the small, reusable integration surface. All app-specific
/// behavior should be driven through these properties instead of editing the
/// bridge internals.
struct ApproovWebViewConfiguration: Sendable {
    /// Your Approov onboarding string.
    let approovConfig: String

    /// The name used by JavaScript when calling
    /// `window.webkit.messageHandlers.<name>.postMessage(...)`.
    let bridgeHandlerName: String

    /// The header that receives the Approov JWT.
    let approovTokenHeaderName: String

    /// Controls fail-open versus fail-closed behavior.
    ///
    /// `true` means a request is still executed if Approov cannot produce a
    /// JWT. `false` means the bridge rejects the request instead.
    let allowRequestsWithoutApproovToken: Bool

    /// Decides which URLs should attempt Approov protection.
    ///
    /// All intercepted requests are executed natively. This closure decides
    /// which of those requests should also attempt to obtain an Approov JWT.
    let shouldAttemptApproovProtection: @Sendable (URL) -> Bool

    /// Gives the host app one place to apply native-only mutations.
    ///
    /// Typical uses include injecting API keys, tenant headers, or other
    /// values that must never be exposed to web content.
    let mutateRequest: @Sendable (URLRequest) -> URLRequest

    /// Logging metadata used by `OSLog`.
    let loggerSubsystem: String
    let loggerCategory: String

    init(
        approovConfig: String,
        bridgeHandlerName: String = "approovBridge",
        approovTokenHeaderName: String = "approov-token",
        allowRequestsWithoutApproovToken: Bool = false,
        shouldAttemptApproovProtection: @escaping @Sendable (URL) -> Bool,
        mutateRequest: @escaping @Sendable (URLRequest) -> URLRequest = { $0 },
        loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "ApproovWebView",
        loggerCategory: String = "ApproovWebViewBridge"
    ) {
        self.approovConfig = approovConfig
        self.bridgeHandlerName = bridgeHandlerName
        self.approovTokenHeaderName = approovTokenHeaderName
        self.allowRequestsWithoutApproovToken = allowRequestsWithoutApproovToken
        self.shouldAttemptApproovProtection = shouldAttemptApproovProtection
        self.mutateRequest = mutateRequest
        self.loggerSubsystem = loggerSubsystem
        self.loggerCategory = loggerCategory
    }
}

/// How the WebView expects the native response to be applied.
private enum ApproovWebViewResponseHandling: String, Decodable {
    /// Return a response object back to JavaScript.
    case response

    /// Treat the response as a current-frame navigation and load it in the
    /// WebView with `loadSimulatedRequest(...)`.
    case navigation
}

/// The browser feature that originated the request.
private enum ApproovWebViewRequestSource: String, Decodable {
    case fetch
    case xhr
    case form
}

/// Shape of the request payload sent from JavaScript into Swift.
///
/// Bodies are base64-encoded so binary and multipart payloads survive the
/// script message hop without lossy string conversion.
private struct ApproovWebViewProxyRequest: Decodable {
    let url: String
    let method: String
    let headers: [String: String]
    let bodyBase64: String?
    let sourcePageURL: String?
    let responseHandling: ApproovWebViewResponseHandling
    let requestSource: ApproovWebViewRequestSource
}

/// Shape of the response payload sent back into JavaScript.
private struct ApproovWebViewProxyResponse: Encodable {
    let url: String
    let status: Int
    let statusText: String
    let headers: [String: String]
    let bodyBase64: String
}

/// Internal representation of a native response that should become a WebView
/// navigation instead of a JavaScript `Response`.
private struct ApproovWebViewNavigationLoad {
    let request: URLRequest
    let response: URLResponse
    let data: Data
}

/// Internal execution result used by the coordinator.
private enum ApproovWebViewExecutionResult {
    case response(ApproovWebViewProxyResponse)
    case navigation(ApproovWebViewNavigationLoad)
}

/// Error cases that can be surfaced back into page JavaScript.
private enum ApproovWebViewBridgeError: LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case invalidRequestBody
    case approovConfigEmpty
    case approovTokenUnavailable(String)
    case nonHTTPResponse
    case webViewUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "The WebView requested an invalid URL: \(url)"
        case let .unsupportedScheme(url):
            return "Only HTTP and HTTPS requests can be proxied by the Approov WebView bridge: \(url)"
        case .invalidRequestBody:
            return "The WebView request body was not valid base64."
        case .approovConfigEmpty:
            return "The Approov config string is empty."
        case let .approovTokenUnavailable(url):
            return "Approov did not produce a JWT for \(url)."
        case .nonHTTPResponse:
            return "Native networking returned a non-HTTP response."
        case .webViewUnavailable:
            return "The WKWebView was released before a navigation response could be applied."
        }
    }
}

/// Thin async wrapper around `WKHTTPCookieStore`.
///
/// WebKit keeps its own cookie store. Native `URLSession` keeps its own cookie
/// storage. Production-ready proxying needs those two worlds to stay aligned so
/// session cookies, CSRF cookies, and login state keep working when a request
/// is executed natively instead of by WebKit itself.
@MainActor
private final class ApproovWebViewCookieBridge {
    private let store: WKHTTPCookieStore

    init(store: WKHTTPCookieStore) {
        self.store = store
    }

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func setCookies(_ cookies: [HTTPCookie]) async {
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }
}

/// Performs the native side of the protected request flow.
///
/// The actor keeps the stateful pieces together:
/// - Approov SDK lazy initialization
/// - cookie synchronization between WebKit and URLSession
/// - request mutation and token injection
/// - dynamic pinning for protected requests via `ApproovURLSession`
/// - the choice between returning a JavaScript response and loading a
///   navigation result back into the WebView
///
/// Important implementation detail:
/// `ApproovURLSession` does not protect the async `URLSession.data(for:)`
/// convenience API. To actually get Approov interception and dynamic pinning
/// we must execute requests through the completion-handler `dataTask(...)`
/// path and wrap that in async/await ourselves.
private actor ApproovWebViewRequestExecutor {
    /// Internal request metadata key used to tell the Approov mutator whether
    /// dynamic pinning should be applied to a specific request.
    ///
    /// We store this as a URL loading-system property so it stays out of the
    /// wire-visible HTTP headers.
    private static let pinningEnabledRequestProperty = "ApproovWebViewBridge.PinningEnabled"

    private let configuration: ApproovWebViewConfiguration
    private let cookieBridge: ApproovWebViewCookieBridge
    private let logger: Logger
    private let cookieStorage = HTTPCookieStorage()
    private let urlSession: ApproovURLSession
    private var didInitializeApproov = false

    init(
        configuration: ApproovWebViewConfiguration,
        cookieBridge: ApproovWebViewCookieBridge
    ) {
        self.configuration = configuration
        self.cookieBridge = cookieBridge
        self.logger = Logger(
            subsystem: configuration.loggerSubsystem,
            category: configuration.loggerCategory
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = cookieStorage
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.httpShouldSetCookies = true
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil
        self.urlSession = ApproovURLSession(configuration: sessionConfiguration)
    }

    /// Executes a page-originated request natively.
    func execute(_ proxyRequest: ApproovWebViewProxyRequest) async throws -> ApproovWebViewExecutionResult {
        let requestContext = try makeRequestContext(from: proxyRequest)
        try await synchronizeCookiesIntoNativeStorage()

        var request = requestContext.request

        // Give the host app a single generic hook for native-only request
        // customization before the request is executed.
        request = configuration.mutateRequest(request)

        var shouldApplyApproovPinning = false

        if configuration.shouldAttemptApproovProtection(requestContext.requestURL) {
            if let approovToken = try await fetchApproovTokenIfPossible(for: requestContext.requestURL) {
                request.setValue(
                    approovToken,
                    forHTTPHeaderField: configuration.approovTokenHeaderName
                )
                shouldApplyApproovPinning = true
            } else if !configuration.allowRequestsWithoutApproovToken {
                throw ApproovWebViewBridgeError.approovTokenUnavailable(
                    requestContext.requestURL.absoluteString
                )
            }
        }

        Self.setPinningEnabled(shouldApplyApproovPinning, on: &request)

        let (data, response) = try await performPinnedRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApproovWebViewBridgeError.nonHTTPResponse
        }

        await synchronizeCookiesBackIntoWebView()

        let finalURL = httpResponse.url ?? requestContext.requestURL
        let proxyResponse = ApproovWebViewProxyResponse(
            url: finalURL.absoluteString,
            status: httpResponse.statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            headers: normalizeHeaders(httpResponse.allHeaderFields),
            bodyBase64: data.base64EncodedString()
        )

        switch proxyRequest.responseHandling {
        case .response:
            return .response(proxyResponse)
        case .navigation:
            // Simulated navigation should use the final response URL so the
            // page is interpreted relative to the post-redirect document URL.
            let simulatedRequest = URLRequest(url: finalURL)
            return .navigation(
                ApproovWebViewNavigationLoad(
                    request: simulatedRequest,
                    response: httpResponse,
                    data: data
                )
            )
        }
    }

    /// Builds the `URLRequest` that native networking should execute.
    private func makeRequestContext(
        from proxyRequest: ApproovWebViewProxyRequest
    ) throws -> (requestURL: URL, request: URLRequest) {
        guard let requestURL = URL(string: proxyRequest.url) else {
            throw ApproovWebViewBridgeError.invalidURL(proxyRequest.url)
        }

        guard Self.isHTTPScheme(requestURL) else {
            throw ApproovWebViewBridgeError.unsupportedScheme(proxyRequest.url)
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = proxyRequest.method.isEmpty ? "GET" : proxyRequest.method.uppercased()

        for (headerName, headerValue) in proxyRequest.headers {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }

        if let bodyBase64 = proxyRequest.bodyBase64, !bodyBase64.isEmpty {
            guard let bodyData = Data(base64Encoded: bodyBase64) else {
                throw ApproovWebViewBridgeError.invalidRequestBody
            }

            request.httpBody = bodyData
        }

        if let sourcePageURL = proxyRequest.sourcePageURL,
           let pageURL = URL(string: sourcePageURL) {
            request.mainDocumentURL = pageURL
            applyBrowserContextHeaders(to: &request, pageURL: pageURL)
        }

        applyCookies(to: &request, for: requestURL)

        return (requestURL, request)
    }

    /// Mirrors the browser's page context onto the native request where doing
    /// so is important for compatibility.
    ///
    /// The browser sets headers such as `Referer` and `Origin` automatically.
    /// Once a request is proxied into native code, we need to reconstruct the
    /// important ones ourselves.
    private func applyBrowserContextHeaders(to request: inout URLRequest, pageURL: URL) {
        if request.value(forHTTPHeaderField: "Referer") == nil {
            request.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        }

        guard shouldApplyOriginHeader(forHTTPMethod: request.httpMethod),
              request.value(forHTTPHeaderField: "Origin") == nil,
              let origin = Self.originString(from: pageURL) else {
            return
        }

        request.setValue(origin, forHTTPHeaderField: "Origin")
    }

    /// Copies cookies from WebKit into the native cookie jar before each
    /// request so the native call sees the same session state as the page.
    private func synchronizeCookiesIntoNativeStorage() async throws {
        let webCookies = await cookieBridge.allCookies()

        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }

        for cookie in webCookies {
            cookieStorage.setCookie(cookie)
        }
    }

    /// Pushes cookies written during the native request back into WebKit.
    ///
    /// This keeps login and CSRF cookies coherent after redirects, API calls,
    /// and form submissions executed natively.
    private func synchronizeCookiesBackIntoWebView() async {
        await cookieBridge.setCookies(cookieStorage.cookies ?? [])
    }

    /// Applies a `Cookie` header if JavaScript did not already supply one.
    private func applyCookies(to request: inout URLRequest, for url: URL) {
        guard request.value(forHTTPHeaderField: "Cookie") == nil,
              let cookies = cookieStorage.cookies(for: url),
              !cookies.isEmpty else {
            return
        }

        for (headerName, headerValue) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(headerValue, forHTTPHeaderField: headerName)
        }
    }

    /// Initializes the Approov SDK lazily the first time a protected request is
    /// attempted.
    private func initializeApproovIfNeeded() throws {
        guard !didInitializeApproov else {
            return
        }

        let trimmedConfig = configuration.approovConfig
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedConfig.isEmpty else {
            throw ApproovWebViewBridgeError.approovConfigEmpty
        }

        try ApproovService.initialize(config: trimmedConfig)
        // The bridge adds the JWT manually, but configuring the same header
        // name in the Approov service keeps the contract aligned with the rest
        // of the app if the SDK is reused elsewhere.
        ApproovService.setApproovHeader(
            header: configuration.approovTokenHeaderName,
            prefix: ""
        )
        ApproovService.setServiceMutator(
            ApproovWebViewPinningMutator(
                shouldApplyPinning: { [configuration] request in
                    Self.shouldApplyPinning(
                        for: request,
                        fallback: configuration.shouldAttemptApproovProtection
                    )
                }
            )
        )

        didInitializeApproov = true
    }

    /// Attempts to obtain a JWT from Approov for the provided URL.
    ///
    /// If the bridge is configured to fail open, Approov failures are logged
    /// and the request proceeds without the token.
    private func fetchApproovTokenIfPossible(for url: URL) async throws -> String? {
        do {
            try initializeApproovIfNeeded()
            let token = try await fetchApproovToken(for: url)

            guard !token.isEmpty else {
                throw ApproovWebViewBridgeError.approovTokenUnavailable(url.absoluteString)
            }

            return token
        } catch {
            guard configuration.allowRequestsWithoutApproovToken else {
                throw error
            }

            logger.notice(
                "Proceeding without an Approov JWT for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Wraps the synchronous SDK call in async/await.
    private func fetchApproovToken(for url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let token = try ApproovService.fetchToken(url: url.absoluteString)
                    continuation.resume(returning: token)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Executes the request through `ApproovURLSession` so the session's
    /// interceptor and pinning delegate are actually involved.
    ///
    /// We intentionally do not use `URLSession.data(for:)` here because the
    /// Approov URLSession wrapper documents that the iOS 15 async transfer APIs
    /// are not protected.
    private func performPinnedRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = urlSession.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: ApproovWebViewBridgeError.nonHTTPResponse)
                    return
                }

                continuation.resume(returning: (data, response))
            }

            task.resume()
        }
    }

    /// Converts Foundation's heterogenous header map into a pure
    /// `[String: String]` dictionary that can be JSON-serialized.
    private func normalizeHeaders(_ rawHeaders: [AnyHashable: Any]) -> [String: String] {
        var headers: [String: String] = [:]

        for (key, value) in rawHeaders {
            headers[String(describing: key)] = String(describing: value)
        }

        return headers
    }

    private func shouldApplyOriginHeader(forHTTPMethod method: String?) -> Bool {
        guard let method else {
            return false
        }

        switch method.uppercased() {
        case "POST", "PUT", "PATCH", "DELETE":
            return true
        default:
            return false
        }
    }

    private static func isHTTPScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "http" || scheme == "https"
    }

    private static func originString(from url: URL) -> String? {
        guard let scheme = url.scheme,
              let host = url.host else {
            return nil
        }

        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }

        return "\(scheme)://\(host)"
    }

    private static func setPinningEnabled(_ enabled: Bool, on request: inout URLRequest) {
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(
            enabled,
            forKey: pinningEnabledRequestProperty,
            in: mutableRequest
        )
        request = mutableRequest as URLRequest
    }

    private static func shouldApplyPinning(
        for request: URLRequest,
        fallback: (URL) -> Bool
    ) -> Bool {
        if let explicitDecision = URLProtocol.property(
            forKey: pinningEnabledRequestProperty,
            in: request
        ) as? Bool {
            return explicitDecision
        }

        guard let url = request.url else {
            return false
        }

        return fallback(url)
    }
}

/// Customizes the Approov URLSession wrapper so this bridge can use:
/// - manual JWT fetch and fail-open/fail-closed behavior from app policy
/// - Approov dynamic pinning for requests that actually received Approov
///   protection
///
/// The interceptor is disabled because the bridge already owns token fetching
/// and request mutation. Pinning remains enabled on a per-request basis.
private final class ApproovWebViewPinningMutator: ApproovServiceMutator {
    private nonisolated(unsafe) let shouldApplyPinning: @Sendable (URLRequest) -> Bool

    nonisolated init(shouldApplyPinning: @escaping @Sendable (URLRequest) -> Bool) {
        self.shouldApplyPinning = shouldApplyPinning
    }

    nonisolated func handleInterceptorShouldProcessRequest(_ request: URLRequest) throws -> Bool {
        false
    }

    nonisolated func handlePinningShouldProcessRequest(_ request: URLRequest) -> Bool {
        shouldApplyPinning(request)
    }
}

/// SwiftUI wrapper around `WKWebView` that installs the Approov bridge.
///
/// This is the only UI type the host app needs to embed. The bridge details,
/// cookie plumbing, and WebKit coordinator logic all stay hidden in this file.
struct ApproovWebView: UIViewRepresentable {
    let content: ApproovWebViewContent
    let configuration: ApproovWebViewConfiguration

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration)
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()

        // Inject the bridge before any page code runs so page scripts cannot
        // race Fetch, XHR, or form submission before the native wrappers exist.
        let bridgeScript = WKUserScript(
            source: ApproovWebViewJavaScriptBridge.scriptSource(
                handlerName: configuration.bridgeHandlerName
            ),
            injectionTime: .atDocumentStart,
            // Production pages often use iframes. Injecting into all frames
            // gives the bridge coverage there as well.
            forMainFrameOnly: false
        )

        userContentController.addUserScript(bridgeScript)
        userContentController.addScriptMessageHandler(
            context.coordinator,
            contentWorld: .page,
            name: configuration.bridgeHandlerName
        )

        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController = userContentController
        webViewConfiguration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Use the default website data store so WebKit cookies persist and can
        // be mirrored into native networking.
        webViewConfiguration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground

        context.coordinator.attach(webView: webView)

        switch content {
        case let .htmlString(html, baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case let .request(request):
            webView.load(request)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

extension ApproovWebView {
    /// Receives JavaScript bridge messages and delegates execution to the actor
    /// that owns the native request pipeline.
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply {
        private let configuration: ApproovWebViewConfiguration
        private let decoder = JSONDecoder()
        private let encoder = JSONEncoder()
        private let logger: Logger
        private weak var webView: WKWebView?
        private var executor: ApproovWebViewRequestExecutor?

        init(configuration: ApproovWebViewConfiguration) {
            self.configuration = configuration
            self.logger = Logger(
                subsystem: configuration.loggerSubsystem,
                category: configuration.loggerCategory
            )
        }

        func attach(webView: WKWebView) {
            self.webView = webView
            self.executor = ApproovWebViewRequestExecutor(
                configuration: configuration,
                cookieBridge: ApproovWebViewCookieBridge(
                    store: webView.configuration.websiteDataStore.httpCookieStore
                )
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            guard let executor else {
                replyHandler(nil, "The native bridge is not ready yet.")
                return
            }

            guard let bodyDictionary = message.body as? [String: Any] else {
                replyHandler(nil, "The WebView bridge payload was not a dictionary.")
                return
            }

            do {
                let bodyData = try JSONSerialization.data(
                    withJSONObject: bodyDictionary,
                    options: []
                )
                let proxyRequest = try decoder.decode(
                    ApproovWebViewProxyRequest.self,
                    from: bodyData
                )

                Task {
                    do {
                        let executionResult = try await executor.execute(proxyRequest)

                        switch executionResult {
                        case let .response(proxyResponse):
                            let replyObject = try makeReplyObject(from: proxyResponse)
                            replyHandler(replyObject, nil)

                        case let .navigation(navigationLoad):
                            try await MainActor.run {
                                try applyNavigationLoad(navigationLoad)
                            }
                            replyHandler(["navigationStarted": true], nil)
                        }
                    } catch {
                        logger.error(
                            "WebView bridge request failed: \(error.localizedDescription, privacy: .public)"
                        )
                        replyHandler(nil, error.localizedDescription)
                    }
                }
            } catch {
                replyHandler(
                    nil,
                    "Failed to decode the WebView request: \(error.localizedDescription)"
                )
            }
        }

        private func makeReplyObject(from response: ApproovWebViewProxyResponse) throws -> Any {
            let encodedResponse = try encoder.encode(response)
            return try JSONSerialization.jsonObject(with: encodedResponse, options: [])
        }

        /// Loads a native response back into the WebView as a real navigation.
        ///
        /// `loadSimulatedRequest(...)` is the public WebKit API that lets us
        /// render a native HTTP response as if it had been produced by a page
        /// navigation to the same URL. This is what makes current-frame form
        /// submissions practical without falling back to `loadHTMLString`.
        @MainActor
        private func applyNavigationLoad(_ navigationLoad: ApproovWebViewNavigationLoad) throws {
            guard let webView else {
                throw ApproovWebViewBridgeError.webViewUnavailable
            }

            webView.loadSimulatedRequest(
                navigationLoad.request,
                response: navigationLoad.response,
                responseData: navigationLoad.data
            )
        }
    }
}

/// Generates the JavaScript bridge injected into the page.
///
/// What it intercepts:
/// - `window.fetch`
/// - `window.XMLHttpRequest`
/// - HTML form submission targeting the current frame
///
/// What it still cannot fully intercept with public APIs:
/// - arbitrary built-in WebKit subresource loads such as `<img>`, `<script>`,
///   and `<iframe>`
/// - WebSockets
/// - Service Worker networking
/// - forms targeting another window or named frame
///
/// Those boundaries are documented in the README because they are platform
/// limits, not omissions in the sample.
private enum ApproovWebViewJavaScriptBridge {
    private static let handlerPlaceholder = "__APPROOV_BRIDGE_HANDLER__"

    static func scriptSource(handlerName: String) -> String {
        template.replacingOccurrences(of: handlerPlaceholder, with: handlerName)
    }

    private static let template = #"""
    (() => {
      const nativeHandler = window.webkit?.messageHandlers?.__APPROOV_BRIDGE_HANDLER__;
      if (!nativeHandler || typeof nativeHandler.postMessage !== "function") {
        return;
      }

      const originalFetch = window.fetch.bind(window);
      const OriginalXMLHttpRequest = window.XMLHttpRequest;
      const originalFormSubmit = HTMLFormElement.prototype.submit;
      const originalRequestSubmit = HTMLFormElement.prototype.requestSubmit
        ? HTMLFormElement.prototype.requestSubmit
        : null;
      const submitterByForm = new WeakMap();
      const textDecoder = new TextDecoder();

      // Serializes arbitrary request bodies into base64 so Swift receives the
      // exact bytes JavaScript intended to place on the network.
      const arrayBufferToBase64 = (buffer) => {
        const bytes = new Uint8Array(buffer);
        const chunkSize = 0x8000;
        let binary = "";

        for (let index = 0; index < bytes.length; index += chunkSize) {
          const chunk = bytes.subarray(index, index + chunkSize);
          binary += String.fromCharCode(...chunk);
        }

        return btoa(binary);
      };

      // Reconstructs the response body returned from Swift.
      const base64ToUint8Array = (base64Value) => {
        const binary = atob(base64Value || "");
        const bytes = new Uint8Array(binary.length);

        for (let index = 0; index < binary.length; index += 1) {
          bytes[index] = binary.charCodeAt(index);
        }

        return bytes;
      };

      // Only proxy ordinary HTTP(S) traffic. Browser-only schemes such as
      // `data:` or `blob:` should keep using the browser stack directly.
      const isNativeProxyCandidate = (urlString) => {
        try {
          const resolvedURL = new URL(urlString, window.location.href);
          return resolvedURL.protocol === "http:" || resolvedURL.protocol === "https:";
        } catch (_error) {
          return false;
        }
      };

      const serializeRequest = async (request, requestSource, responseHandling) => {
        const headers = {};
        request.headers.forEach((value, key) => {
          headers[key] = value;
        });

        let bodyBase64 = null;
        if (request.method !== "GET" && request.method !== "HEAD") {
          const bodyBuffer = await request.clone().arrayBuffer();
          bodyBase64 = bodyBuffer.byteLength === 0 ? null : arrayBufferToBase64(bodyBuffer);
        }

        return {
          url: request.url,
          method: request.method,
          headers,
          bodyBase64,
          sourcePageURL: window.location.href,
          responseHandling,
          requestSource,
        };
      };

      const serializeBody = async (bodyValue) => {
        if (bodyValue == null) {
          return null;
        }

        const request = new Request("https://approov.invalid/body", {
          method: "POST",
          body: bodyValue,
        });

        const bodyBuffer = await request.arrayBuffer();
        return bodyBuffer.byteLength === 0 ? null : arrayBufferToBase64(bodyBuffer);
      };

      const makeFetchResponse = (nativeResponse) => {
        const responseBytes = base64ToUint8Array(nativeResponse.bodyBase64);
        return new Response(responseBytes, {
          status: nativeResponse.status,
          statusText: nativeResponse.statusText,
          headers: nativeResponse.headers,
        });
      };

      const dispatchFormEvent = (form, eventName, detail) => {
        form.dispatchEvent(new CustomEvent(eventName, {
          bubbles: true,
          detail,
        }));
      };

      const resolveFormAction = (form, submitter) => {
        const rawAction = submitter?.getAttribute("formaction")
          || form.getAttribute("action")
          || window.location.href;

        return new URL(rawAction, window.location.href).toString();
      };

      const resolveFormMethod = (form, submitter) => {
        const rawMethod = submitter?.getAttribute("formmethod")
          || form.getAttribute("method")
          || "GET";
        return rawMethod.toUpperCase();
      };

      const resolveFormEnctype = (form, submitter) => {
        const rawEnctype = submitter?.getAttribute("formenctype")
          || form.getAttribute("enctype")
          || "application/x-www-form-urlencoded";
        return rawEnctype.toLowerCase();
      };

      const resolveFormTarget = (form, submitter) => {
        const rawTarget = submitter?.getAttribute("formtarget")
          || form.getAttribute("target")
          || "_self";
        return rawTarget.toLowerCase();
      };

      const resolveFormResponseHandling = (form) => {
        const requestedMode = (form.dataset.approovSubmitMode || "navigation").toLowerCase();
        return requestedMode === "response" ? "response" : "navigation";
      };

      const appendSubmitterToFormData = (formData, submitter) => {
        if (submitter && submitter.name) {
          formData.append(submitter.name, submitter.value || "");
        }
      };

      const appendFormValueToSearchParams = (searchParams, name, value) => {
        if (value instanceof File) {
          searchParams.append(name, value.name);
          return;
        }

        searchParams.append(name, value);
      };

      const encodeTextPlainFormData = (formData) => {
        const lines = [];

        formData.forEach((value, name) => {
          if (value instanceof File) {
            lines.push(`${name}=${value.name}`);
            return;
          }

          lines.push(`${name}=${value}`);
        });

        return lines.join("\r\n");
      };

      const serializeFormSubmission = async (form, submitter) => {
        const method = resolveFormMethod(form, submitter);
        const enctype = resolveFormEnctype(form, submitter);
        const actionURL = resolveFormAction(form, submitter);
        const responseHandling = resolveFormResponseHandling(form);
        const formData = new FormData(form);

        appendSubmitterToFormData(formData, submitter);

        let requestURL = new URL(actionURL);
        let body = null;

        if (method === "GET" || method === "HEAD") {
          const query = new URLSearchParams(requestURL.search);
          formData.forEach((value, name) => {
            appendFormValueToSearchParams(query, name, value);
          });
          requestURL.search = query.toString();
        } else {
          switch (enctype) {
            case "multipart/form-data":
              body = formData;
              break;
            case "text/plain":
              body = encodeTextPlainFormData(formData);
              break;
            case "application/x-www-form-urlencoded":
            default: {
              const searchParams = new URLSearchParams();
              formData.forEach((value, name) => {
                appendFormValueToSearchParams(searchParams, name, value);
              });
              body = searchParams;
              break;
            }
          }
        }

        const request = new Request(requestURL.toString(), {
          method,
          body,
          headers: {
            // HTML form navigations typically expect a document response.
            Accept: responseHandling === "navigation"
              ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
              : "*/*",
          },
        });

        return serializeRequest(request, "form", responseHandling);
      };

      const isSubmitControl = (element) => {
        if (element instanceof HTMLButtonElement) {
          return element.type === "submit" || element.type === "";
        }

        if (element instanceof HTMLInputElement) {
          return element.type === "submit";
        }

        return false;
      };

      const isNativeHandledForm = (form, submitter) => {
        const method = resolveFormMethod(form, submitter);
        if (method === "DIALOG") {
          return false;
        }

        const actionURL = resolveFormAction(form, submitter);
        if (!isNativeProxyCandidate(actionURL)) {
          return false;
        }

        // Current-frame form submission is the production-safe path that can
        // be modeled with `loadSimulatedRequest(...)`.
        const target = resolveFormTarget(form, submitter);
        return target === "" || target === "_self";
      };

      const handleNativeFormResponse = (form, nativeResponse) => {
        const bodyBytes = base64ToUint8Array(nativeResponse.bodyBase64);
        const bodyText = textDecoder.decode(bodyBytes);

        dispatchFormEvent(form, "approov:form-response", {
          url: nativeResponse.url,
          status: nativeResponse.status,
          statusText: nativeResponse.statusText,
          ok: nativeResponse.status >= 200 && nativeResponse.status < 300,
          headers: nativeResponse.headers,
          bodyText,
          bodyBase64: nativeResponse.bodyBase64,
        });
      };

      const handleNativeFormError = (form, error) => {
        const message = error?.message || String(error);
        dispatchFormEvent(form, "approov:form-error", {
          message,
        });
      };

      const proxyFormSubmission = async (form, submitter) => {
        if (form.dataset.approovSubmitting === "true") {
          return;
        }

        form.dataset.approovSubmitting = "true";

        try {
          const payload = await serializeFormSubmission(form, submitter);
          const nativeResponse = await nativeHandler.postMessage(payload);

          if (payload.responseHandling === "response") {
            handleNativeFormResponse(form, nativeResponse);
          }
        } catch (error) {
          handleNativeFormError(form, error);
        } finally {
          delete form.dataset.approovSubmitting;
          submitterByForm.delete(form);
        }
      };

      // Replace Fetch with a transparent native proxy. Page code still calls
      // `fetch(...)` as normal and receives a normal `Response`.
      window.fetch = async (input, init) => {
        const request = input instanceof Request && init === undefined
          ? input
          : new Request(input, init);

        if (!isNativeProxyCandidate(request.url)) {
          return originalFetch(input, init);
        }

        const payload = await serializeRequest(
          request,
          "fetch",
          "response",
        );
        const nativeResponse = await nativeHandler.postMessage(payload);
        return makeFetchResponse(nativeResponse);
      };

      // XMLHttpRequest is also wrapped because many WebView apps still use it.
      class ApproovXMLHttpRequest {
        constructor() {
          this.readyState = 0;
          this.status = 0;
          this.statusText = "";
          this.response = null;
          this.responseText = "";
          this.responseType = "";
          this.responseURL = "";
          this.onreadystatechange = null;
          this.onload = null;
          this.onerror = null;
          this.onloadend = null;
          this.onabort = null;
          this._headers = {};
          this._responseHeaders = {};
          this._listeners = {};
          this._fallback = null;
          this._url = "";
          this._method = "GET";
        }

        open(method, url, async = true, user = null, password = null) {
          this._method = (method || "GET").toUpperCase();
          this._url = new URL(url, window.location.href).toString();
          this._headers = {};
          this._responseHeaders = {};
          this._fallback = null;

          if (!isNativeProxyCandidate(this._url)) {
            this._fallback = new OriginalXMLHttpRequest();
            this._wireFallback();
            this._fallback.responseType = this.responseType;
            this._fallback.open(method, url, async, user, password);
            return;
          }

          this._changeReadyState(1);
        }

        setRequestHeader(name, value) {
          if (this._fallback) {
            this._fallback.setRequestHeader(name, value);
            return;
          }

          this._headers[name] = value;
        }

        getResponseHeader(name) {
          if (this._fallback) {
            return this._fallback.getResponseHeader(name);
          }

          return this._responseHeaders[name.toLowerCase()] || null;
        }

        getAllResponseHeaders() {
          if (this._fallback) {
            return this._fallback.getAllResponseHeaders();
          }

          return Object.entries(this._responseHeaders)
            .map(([name, value]) => `${name}: ${value}`)
            .join("\r\n");
        }

        addEventListener(type, listener) {
          this._listeners[type] = this._listeners[type] || new Set();
          this._listeners[type].add(listener);
        }

        removeEventListener(type, listener) {
          this._listeners[type]?.delete(listener);
        }

        abort() {
          if (this._fallback) {
            this._fallback.abort();
            return;
          }

          this._dispatch("abort");
          this._dispatch("loadend");
        }

        async send(body = null) {
          if (this._fallback) {
            this._fallback.send(body);
            return;
          }

          try {
            const nativeResponse = await nativeHandler.postMessage({
              url: this._url,
              method: this._method,
              headers: this._headers,
              bodyBase64: await serializeBody(body),
              sourcePageURL: window.location.href,
              responseHandling: "response",
              requestSource: "xhr",
            });

            this.status = nativeResponse.status;
            this.statusText = nativeResponse.statusText;
            this.responseURL = nativeResponse.url || this._url;
            this._responseHeaders = Object.fromEntries(
              Object.entries(nativeResponse.headers).map(([name, value]) => [name.toLowerCase(), value]),
            );

            this._changeReadyState(2);
            this._changeReadyState(3);
            this._applyResponseBody(base64ToUint8Array(nativeResponse.bodyBase64));
            this._changeReadyState(4);
            this._dispatch("load");
            this._dispatch("loadend");
          } catch (error) {
            this._changeReadyState(4);
            this._dispatch("error", error);
            this._dispatch("loadend");
          }
        }

        _applyResponseBody(responseBytes) {
          switch (this.responseType) {
            case "arraybuffer":
              this.response = responseBytes.buffer;
              this.responseText = "";
              break;
            case "blob":
              this.response = new Blob([responseBytes]);
              this.responseText = "";
              break;
            case "json": {
              const textValue = textDecoder.decode(responseBytes);
              this.responseText = textValue;
              this.response = textValue ? JSON.parse(textValue) : null;
              break;
            }
            case "":
            case "text":
            default: {
              const textValue = textDecoder.decode(responseBytes);
              this.responseText = textValue;
              this.response = textValue;
            }
          }
        }

        _changeReadyState(nextState) {
          this.readyState = nextState;
          this._dispatch("readystatechange");
        }

        _dispatch(type, detail = null) {
          const event = new Event(type);
          event.detail = detail;

          const propertyHandler = this[`on${type}`];
          if (typeof propertyHandler === "function") {
            propertyHandler.call(this, event);
          }

          this._listeners[type]?.forEach((listener) => {
            listener.call(this, event);
          });
        }

        _wireFallback() {
          const eventNames = ["readystatechange", "load", "error", "loadend", "abort"];

          eventNames.forEach((eventName) => {
            this._fallback.addEventListener(eventName, (event) => {
              this._syncFromFallback();
              this._dispatch(eventName, event);
            });
          });
        }

        _syncFromFallback() {
          this.readyState = this._fallback.readyState;
          this.status = this._fallback.status;
          this.statusText = this._fallback.statusText;
          this.response = this._fallback.response;
          this.responseType = this._fallback.responseType;
          this.responseURL = this._fallback.responseURL;

          try {
            this.responseText = typeof this._fallback.responseText === "string"
              ? this._fallback.responseText
              : "";
          } catch (_error) {
            this.responseText = "";
          }
        }
      }

      document.addEventListener("click", (event) => {
        const clickedElement = event.target instanceof Element
          ? event.target.closest("button, input")
          : null;

        if (!isSubmitControl(clickedElement) || !clickedElement.form) {
          return;
        }

        submitterByForm.set(clickedElement.form, clickedElement);
      }, true);

      document.addEventListener("submit", (event) => {
        const form = event.target;
        if (!(form instanceof HTMLFormElement)) {
          return;
        }

        const submitter = event.submitter || submitterByForm.get(form) || null;
        if (!isNativeHandledForm(form, submitter)) {
          return;
        }

        event.preventDefault();
        void proxyFormSubmission(form, submitter);
      }, true);

      // `form.submit()` bypasses the normal submit event, so it must be wrapped
      // explicitly if programmatic submission should also be protected.
      HTMLFormElement.prototype.submit = function () {
        const form = this;
        const submitter = submitterByForm.get(form) || null;

        if (!isNativeHandledForm(form, submitter)) {
          return originalFormSubmit.call(form);
        }

        void proxyFormSubmission(form, submitter);
      };

      // Keep `requestSubmit()` semantics intact but remember the submitter so
      // the subsequent `submit` event sees the correct form overrides.
      if (originalRequestSubmit) {
        HTMLFormElement.prototype.requestSubmit = function (submitter) {
          if (submitter) {
            submitterByForm.set(this, submitter);
          }

          return originalRequestSubmit.call(this, submitter);
        };
      }

      window.XMLHttpRequest = ApproovXMLHttpRequest;
      window.__approovBridgeEnabled = true;
      window.__approovBridgeFeatures = {
        fetch: true,
        xhr: true,
        forms: true,
        cookieSync: true,
        simulatedNavigations: true,
      };
    })();
    """#
}
