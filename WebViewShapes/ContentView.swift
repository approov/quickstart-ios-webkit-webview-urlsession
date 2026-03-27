//
//  ContentView.swift
//  WebViewShapes
//
//  Starts on a host-selection screen, then pushes into either demo.
//
//  Comment out one of the navigation links below if you want the sample to
//  present only a single hosting style while keeping the other nearby for
//  reference.
//

import ApproovServiceWebView
import SwiftUI

struct ContentView: View {
    @State private var selectedHostDemo: HostDemo?

    var body: some View {
        Group {
            if let selectedHostDemo {
                HostDemoScreen(
                    demo: selectedHostDemo,
                    onBack: { self.selectedHostDemo = nil }
                )
            } else {
                List {
                    Section("Host Demo") {
                ForEach(HostDemo.allCases) { demo in
                            Button {
                                selectedHostDemo = demo
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(demo.title)
                                    Text(demo.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
}

private enum HostDemo: String, CaseIterable, Identifiable {
    case swiftUI
    case uiKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swiftUI:
            return "SwiftUI"
        case .uiKit:
            return "UIKit"
        }
    }

    var summary: String {
        switch self {
        case .swiftUI:
            return "Uses the `ApproovWebView` SwiftUI wrapper directly."
        case .uiKit:
            return "Uses a native `UIViewController` host, then embeds it back into this sample with `UIViewControllerRepresentable`."
        }
    }

}

private struct HostDemoScreen: View {
    let demo: HostDemo
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back", action: onBack)
                Spacer()
                Text(demo.title)
                    .font(.headline)
                Spacer()
                Color.clear
                    .frame(width: 44, height: 1)
            }
            .padding()

            Divider()

            Text(demo.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

            demoView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var demoView: some View {
        switch demo {
        // Keep this case if you want the sample to show the SwiftUI-native host.
        case .swiftUI:
            ApproovWebView(
                content: QuickstartConfiguration.initialContent,
                configuration: QuickstartConfiguration.webViewConfiguration
            )
        // Keep this case if you want the sample to show the UIKit-native host.
        case .uiKit:
            UIKitApproovWebViewControllerContainer(
                content: QuickstartConfiguration.initialContent,
                configuration: QuickstartConfiguration.webViewConfiguration
            )
        }
    }
}

/// Lets the sample app render the UIKit controller without changing the app's
/// SwiftUI lifecycle. A UIKit-only customer does not need this wrapper.
private struct UIKitApproovWebViewControllerContainer: UIViewControllerRepresentable {
    let content: ApproovWebViewContent
    let configuration: ApproovWebViewConfiguration

    func makeUIViewController(context: Context) -> ApproovWebViewController {
        ApproovWebViewController(
            content: content,
            configuration: configuration
        )
    }

    func updateUIViewController(
        _ uiViewController: ApproovWebViewController,
        context: Context
    ) {}
}

#Preview {
    ContentView()
}
