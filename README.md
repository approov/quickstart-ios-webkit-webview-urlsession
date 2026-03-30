# Approov WebView Quickstart for iOS

This repository is now just the sample app.

It demonstrates how to host an Approov-protected `WKWebView` in iOS by using the external `ApproovServiceWebView` Swift package, rather than shipping the bridge and service-layer source code inside this repo.

## What This Repo Contains

The app shows three quickstart flows:

1. A SwiftUI-hosted WebView that loads a bundled local HTML page.
2. A UIKit-hosted WebView that loads the same bundled local HTML page.
3. A hosted WebView example that loads a remote site and protects a separate API origin.

The package implementation is not stored in this repository. The Xcode project depends on:

- `https://github.com/approov/approov-service-ios-webview.git`

That package provides:

- `ApproovWebView`
- `ApproovWebViewController`
- `ApproovWebViewConfiguration`
- `ApproovWebViewProtectedEndpoint`

## Why This Architecture Exists

Public `WKWebView` APIs do not give you a supported way to mutate headers on arbitrary built-in browser requests before WebKit sends them.

For Approov protection, the supported pattern is:

1. Load your page in `WKWebView`.
2. Let the package inject a JavaScript bridge at document start.
3. Proxy only allowlisted Fetch, XHR, and supported same-frame form submissions into native code.
4. Use native Swift to apply Approov protection, cookie sync, pinning, and any native-only headers.
5. Return the response back to the page so the web app can keep using normal browser APIs.

This repo shows the app-side wiring for that pattern.

## Current Sample Layout

- `WebViewShapes/ContentView.swift`
  - Demo chooser for SwiftUI, UIKit, and hosted remote content.
- `WebViewShapes/QuickstartConfiguration.swift`
  - App-specific Approov config, allowlists, hosted URL placeholders, and native-only header injection.
- `WebViewShapes/ShapesQuickstartPage.swift`
  - Resolves the bundled local HTML page into `ApproovWebViewContent`.
- `WebViewShapes/WebAssets/index.html`
  - The bundled local page used by the SwiftUI and UIKit demos.
- `JS_BRIDGE_DESIGN.md`
  - Design notes for the bridge-based approach used by the external package.

## What The Quickstart Demonstrates

The sample is designed around the browser flows the package protects:

- `fetch(...)`
- `XMLHttpRequest`
- current-frame HTML form submission

The bundled page demonstrates:

- a protected Fetch request to `https://shapes.approov.io/v2/shapes`
- a plain HTML form that submits to the same protected API
- native-only API key injection so the page never sees the secret

The hosted example demonstrates:

- loading a remote site in the WebView
- protecting a separate API origin with an `/api` allowlist
- keeping app-specific remote URL and API host configuration in one place

## Current Configuration Model

All quickstart-specific values live in `WebViewShapes/QuickstartConfiguration.swift`.

The current sample has two configurations:

- `localWebViewConfiguration`
  - For the bundled Shapes demo page.
  - Protects `shapes.approov.io` on `/v2`.
  - Injects the Shapes `Api-Key` natively.
- `hostedWebViewConfiguration`
  - For the remote hosted demo page.
  - Uses placeholder values like `https://webview.example-api.com/` and `example-api.com/api`.
  - Intended for customers to replace with their own remote web app and API.

The current sample content sources are:

- `localContent`
  - Bundled `WebAssets/index.html`
- `hostedContent`
  - A `URLRequest` to `hostedWebViewURL`

## What You Need To Replace

Before using this quickstart in a real project, replace the placeholder/demo values in `WebViewShapes/QuickstartConfiguration.swift`:

- `approovConfig`
- `approovDevelopmentKey`
- `hostedWebViewURL`
- hosted `protectedEndpoints`
- any demo API domains and keys you do not want to keep

For the local Shapes demo specifically, update as needed:

- `shapesEndpoint`
- `shapesAPIKey`
- `protectedEndpoints`
- `mutateRequest`

## Using The Quickstart In Your Own App

### 1. Add the package dependency

Add:

- `https://github.com/approov/approov-service-ios-webview.git`

The package itself depends on:

- `https://github.com/approov/approov-service-urlsession.git`
- `https://github.com/approov/approov-ios-sdk.git`

### 2. Import the package

```swift
import ApproovServiceWebView
```

### 3. Create your configuration

```swift
let configuration = ApproovWebViewConfiguration(
    approovConfig: "<your-approov-config>",
    protectedEndpoints: [
        ApproovWebViewProtectedEndpoint(
            host: "api.example.com",
            pathPrefix: "/api"
        )
    ],
    approovTokenHeaderName: "approov-token",
    approovDevelopmentKey: "<your-dev-key>",
    allowRequestsWithoutApproovToken: false,
    mutateRequest: { request in
        var request = request

        if request.url?.host?.lowercased() == "api.example.com" {
            request.setValue("native-only-secret", forHTTPHeaderField: "Api-Key")
        }

        return request
    }
)
```

### 4. Present the WebView

Hosted content:

```swift
ApproovWebView(
    content: .request(URLRequest(url: URL(string: "https://web.example.com")!)),
    configuration: configuration
)
```

Bundled file content:

```swift
ApproovWebView(
    content: .fileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent()),
    configuration: configuration
)
```

UIKit host:

```swift
ApproovWebViewController(
    content: .request(URLRequest(url: URL(string: "https://web.example.com")!)),
    configuration: configuration
)
```

## Platform Limits

This quickstart intentionally focuses on the flows the package is designed to protect.

It does not claim transparent interception for every WebKit-managed network primitive, including:

- arbitrary `<img>` requests
- arbitrary `<script>` requests
- arbitrary iframe subresource requests
- CSS subresources
- WebSockets
- Service Worker networking
- forms targeting another frame or window
- full parity for all Fetch/XHR semantics such as abort and streaming progress

The safe production pattern is to keep protected API traffic on:

- `fetch`
- `XMLHttpRequest`
- current-frame form submission

## Production Notes

- Prefer a strict allowlist in `protectedEndpoints`.
- Keep native-only secrets in `mutateRequest`, never in page JavaScript.
- Use `allowRequestsWithoutApproovToken = false` for production unless you explicitly want fail-open behavior.
- Keep the app-specific integration surface small and isolated in a file like `QuickstartConfiguration.swift`.

## Sources

- [Approov Service for iOS WebView](https://github.com/approov/approov-service-ios-webview)
- [Approov Service for URLSession](https://github.com/approov/approov-service-urlsession)
- [Approov iOS Swift URLSession quickstart](https://github.com/approov/quickstart-ios-swift-urlsession)
- [Apple `WKScriptMessageHandlerWithReply`](https://developer.apple.com/documentation/webkit/wkscriptmessagehandlerwithreply)
- [Apple `WKHTTPCookieStore`](https://developer.apple.com/documentation/webkit/wkhttpcookiestore)
- [Apple `WKWebView.loadSimulatedRequest`](https://developer.apple.com/documentation/webkit/wkwebview/loadsimulatedrequest(_:response:responsedata:))
