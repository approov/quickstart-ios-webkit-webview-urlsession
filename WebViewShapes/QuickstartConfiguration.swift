//
//  QuickstartConfiguration.swift
//  WebViewShapes
//
//  This file is intentionally small and app-specific.
//
//  Reuse guidance:
//  - In a real app, this is the only place most teams should need to edit.
//  - Keep the generic bridge implementation untouched in
//    `ApproovServiceWebView`.
//  - Swap in your own Approov config string, API domains, and any native-only
//    header mutations.
//

import ApproovServiceWebView
import Foundation

enum QuickstartConfiguration {
    /// The Approov onboarding string for this quickstart app.
    ///
    /// In production, many teams prefer to inject this at build time via xcconfig
    /// or environment-specific build settings. It is hardcoded here so the
    /// quickstart is self-contained.
    private static let approovConfig = "#cb-adriant#RyZqOkFZZAUP9JMH7TgJvQzlqe8c1D+8JjCgIbwrIKc="
    /// The protected API endpoint used by the Shapes demo page inside the WebView.
    static let shapesEndpoint = URL(string: "https://shapes.approov.io/v2/shapes")!

    /// The demo endpoint also requires an API key.
    ///
    /// The key is kept in native code and injected right before the request is
    /// sent so the page's JavaScript never needs to know it.
    private static let shapesAPIKey = "yXClypapWNHIifHUWmBIyPFAm"

    /// The reusable bridge configuration given to `ApproovWebView`.
    static let webViewConfiguration = ApproovWebViewConfiguration(
        approovConfig: approovConfig,
        protectedEndpoints: [
            ApproovWebViewProtectedEndpoint(
                host: "shapes.approov.io",
                pathPrefix: "/v2/shapes"
            )
        ],
        approovTokenHeaderName: "approov-token",
        approovDevelopmentKey: "l_zPzVpmXN8oKwQ-",
        // This quickstart uses fail-open semantics because the earlier request
        // asked for the API call to proceed even if Approov cannot produce a JWT.
        allowRequestsWithoutApproovToken: true,
        mutateRequest: { request in
            var request = request

            // This is where app-specific native-only headers belong. Anything
            // added here is invisible to the page's JavaScript.
            if request.url == shapesEndpoint,
               request.value(forHTTPHeaderField: "Api-Key") == nil {
                request.setValue(shapesAPIKey, forHTTPHeaderField: "Api-Key")
            }

            return request
        }
    )

    /// The local HTML page loaded into the WebView for the quickstart demo.
    static let initialContent = ApproovWebViewContent.htmlString(
        ShapesQuickstartPage.html(protectedEndpoint: shapesEndpoint),
        baseURL: nil
    )
}
