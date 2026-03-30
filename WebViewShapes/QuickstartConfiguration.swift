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
    private static let approovConfig = "#cb-adriant#thisShouldBeYourConfigStringxxxxxxxxxxxxxxx="
    /// The protected API endpoint used by the Shapes demo page inside the WebView.
    static let shapesEndpoint = URL(string: "https://shapes.approov.io/v2/shapes")!
    static let hostedWebViewURL = URL(string: "https://webview.example-api.com/")!

    /// The demo endpoint also requires an API key.
    ///
    /// The key is kept in native code and injected right before the request is
    /// sent so the page's JavaScript never needs to know it.
    private static let shapesAPIKey = "yXClypapWNHIifHUWmBIyPFAm"

    /// The local Shapes quickstart loaded from the app bundle.
    static let localContent = ShapesQuickstartPage.initialContent

    /// The reusable bridge configuration for the bundled Shapes quickstart.
    static let localWebViewConfiguration: ApproovWebViewConfiguration = {
        let shapesHost = shapesEndpoint.host ?? "shapes.approov.io"
        let shapesAPIKey = QuickstartConfiguration.shapesAPIKey

        return ApproovWebViewConfiguration(
            approovConfig: approovConfig,
            protectedEndpoints: [
                ApproovWebViewProtectedEndpoint(
                    host: "shapes.approov.io",
                    pathPrefix: "/v2"
                )
            ],
            approovTokenHeaderName: "approov-token",
            approovDevelopmentKey: "thisIsYourDevKey",
            // This quickstart uses fail-open semantics because the earlier request
            // asked for the API call to proceed even if Approov cannot produce a JWT.
            allowRequestsWithoutApproovToken: true,
            mutateRequest: { request in
                var request = request

                // This is where app-specific native-only headers belong. Anything
                // added here is invisible to the page's JavaScript.
                if request.url?.host == shapesHost,
                   request.url?.path.hasPrefix("/v2") == true,
                   request.value(forHTTPHeaderField: "Api-Key") == nil {
                    request.setValue(shapesAPIKey, forHTTPHeaderField: "Api-Key")
                }

                return request
            }
        )
    }()

    /// The hosted web app used for remote WebView verification.
    static let hostedContent = ApproovWebViewContent.request(
        URLRequest(url: hostedWebViewURL)
    )

    /// The remote PawPass app uses the separate anima-api origin for protected
    /// operations like availability, booking, and integration-lab native tests.
    static let hostedWebViewConfiguration = ApproovWebViewConfiguration(
        approovConfig: approovConfig,
        protectedEndpoints: [
            ApproovWebViewProtectedEndpoint(
                host: "example-api.com",
                pathPrefix: "/api"
            )
        ],
        approovTokenHeaderName: "approov-token",
        approovDevelopmentKey: "thisIsYourDevKey",
        allowRequestsWithoutApproovToken: true
    )
}
