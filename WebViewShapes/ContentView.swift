//
//  ContentView.swift
//  WebViewShapes
//
//  Hosts the quickstart WebView.
//
//  The UI layer intentionally stays tiny. The reusable integration lives in
//  `ApproovWebViewBridge.swift`, while `QuickstartConfiguration.swift` provides
//  the app-specific values for this demo.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ApproovWebView(
            content: QuickstartConfiguration.initialContent,
            configuration: QuickstartConfiguration.webViewConfiguration
        )
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
