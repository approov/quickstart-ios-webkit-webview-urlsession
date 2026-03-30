//
//  ShapesQuickstartPage.swift
//  WebViewShapes
//
//  Resolves the real bundled page used by the quickstart.
//

import ApproovServiceWebView
import Foundation

enum ShapesQuickstartPage {
    static let initialContent: ApproovWebViewContent = {
        let assetURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebAssets"
        ) ?? Bundle.main.url(
            forResource: "index",
            withExtension: "html"
        )

        guard let assetURL else {
            fatalError("Missing bundled WebView asset at WebAssets/index.html")
        }

        return .fileURL(
            assetURL,
            allowingReadAccessTo: assetURL.deletingLastPathComponent()
        )
    }()
}
