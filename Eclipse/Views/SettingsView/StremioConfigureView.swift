import SwiftUI

#if os(tvOS)
import AuthenticationServices
#else
import WebKit
#endif

struct StremioConfigureView: View {
    let addon: StremioAddon
    let manager: StremioAddonManager
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var error: String?
    @State private var manualConfiguredURL = ""
#if os(tvOS)
    @State private var authenticationSession: ASWebAuthenticationSession?
    @State private var authenticationMessage: String?
#endif

    /// Derive the configure page URL, preserving the current config path.
    /// e.g. "https://torrentio.strem.fun/sort=qualitysize|..." to ".../sort=qualitysize|.../configure"
    /// If the base has no config path, falls back to "{origin}/configure".
    private var configureURL: URL? {
        StremioClient.configurationPageURL(from: addon.configuredURL)
    }

    var body: some View {
        NavigationView {
            Group {
#if os(tvOS)
                tvOSFallbackView
#else
                if let error = error {
                    errorView(message: error)
                } else if let url = configureURL {
                    if #available(iOS 16.0, *) {
                        configureWebContent(url: url)
                    } else {
                        iOS15ConfigureFallback(url: url)
                    }
                } else {
                    errorView(message: "Unable to determine configure URL for this addon.")
                }
#endif
            }
            .navigationTitle("Configure \(addon.manifest.name)")
#if os(tvOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
#else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
#endif
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

#if !os(tvOS)
    @ViewBuilder
    private func configureWebContent(url: URL) -> some View {
        StremioConfigureWebView(
            url: url,
            isLoading: $isLoading,
            onConfigured: { newURL in
                applyConfiguration(newURL)
            },
            onError: { msg in
                error = msg
            }
        )
        .overlay {
            if isLoading {
                EclipseLoadingIndicator("Loading configuration...")
            }
        }
    }

    @ViewBuilder
    private func iOS15ConfigureFallback(url: URL) -> some View {
        VStack(spacing: 0) {
            configureWebContent(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Configured addon URL")
                    .font(.headline)

                TextField("https://addon.example/...", text: $manualConfiguredURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                Button("Save") {
                    applyConfiguration(manualConfiguredURL)
                }
                .disabled(manualConfiguredURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            .background(Color.black.opacity(0.08))
        }
    }
#endif

#if os(tvOS)
    @ViewBuilder
    private var tvOSFallbackView: some View {
        VStack(spacing: 24) {
            Image(systemName: "safari")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Open the addon's secure configuration page. If it cannot return automatically, paste the configured manifest URL below.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let url = configureURL {
                Button {
                    startAuthenticationSession(url: url)
                } label: {
                    Label("Open Configuration", systemImage: "rectangle.portrait.and.arrow.right")
                }

                Text("Configuration is provided by \(url.host ?? "the addon provider").")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Configured manifest URL")
                    .font(.headline)

                TextField("https://addon.example/.../manifest.json", text: $manualConfiguredURL)

                Button {
                    applyConfiguration(manualConfiguredURL)
                } label: {
                    Label("Save Configured URL", systemImage: "checkmark.circle")
                }
                .disabled(manualConfiguredURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 900)

            if let authenticationMessage {
                Text(authenticationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private func startAuthenticationSession(url: URL) {
        authenticationMessage = nil
        error = nil

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "stremio"
        ) { callbackURL, sessionError in
            DispatchQueue.main.async {
                self.authenticationSession = nil

                if let callbackURL {
                    let configuredURL = StremioClient.normalizedConfiguredURL(from: callbackURL.absoluteString)
                    self.applyConfiguration(configuredURL)
                    return
                }

                if sessionError != nil {
                    self.authenticationMessage = "Configuration did not return to Eclipse. Your typed URL is still here, so you can paste the configured manifest manually."
                }
            }
        }
        authenticationSession = session
        if !session.start() {
            authenticationSession = nil
            authenticationMessage = "The configuration page could not be opened. Paste the configured manifest URL manually."
        }
    }
#endif

    private func applyConfiguration(_ newURL: String) {
        Task {
            do {
                try await manager.reconfigureAddon(addon, newURL: StremioClient.normalizedConfiguredURL(from: newURL))
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - WKWebView wrapper (iOS only)

#if !os(tvOS)
struct StremioConfigureWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onConfigured: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let js = """
        (function() {
            function sendInstall(url) {
                if (typeof url === 'string' && url.toLowerCase().startsWith('stremio://')) {
                    window.webkit.messageHandlers.stremioInstall.postMessage(url);
                    return true;
                }
                return false;
            }

            document.addEventListener('click', function(e) {
                var target = e.target;
                while (target && target.tagName !== 'A') { target = target.parentElement; }
                if (target && target.href && sendInstall(target.href)) {
                    e.preventDefault();
                    e.stopPropagation();
                }
            }, true);

            var origAssign = window.location.assign;
            window.location.assign = function(url) {
                if (sendInstall(url)) { return; }
                origAssign.call(window.location, url);
            };

            var origReplace = window.location.replace;
            window.location.replace = function(url) {
                if (sendInstall(url)) { return; }
                origReplace.call(window.location, url);
            };

            var origOpen = window.open;
            window.open = function(url) {
                if (sendInstall(url)) { return null; }
                return origOpen.apply(window, arguments);
            };
        })();
        """
        let userScript = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "stremioInstall")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        let parent: StremioConfigureWebView

        init(parent: StremioConfigureWebView) {
            self.parent = parent
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "stremioInstall", let urlString = message.body as? String {
                handleInstallURL(urlString)
            }
        }

        // MARK: - WKUIDelegate

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            if let url = navigationAction.request.url {
                if handleInstallURL(url.absoluteString) {
                    return nil
                }
                webView.load(navigationAction.request)
            }
            return nil
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.onError(error.localizedDescription)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.onError(error.localizedDescription)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let urlString = url.absoluteString

            if handleInstallURL(urlString) {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        @discardableResult
        private func handleInstallURL(_ urlString: String) -> Bool {
            guard urlString.lowercased().hasPrefix("stremio://") else { return false }
            let configuredURL = extractConfiguredURL(from: urlString)
            DispatchQueue.main.async {
                self.parent.onConfigured(configuredURL)
            }
            return true
        }

        private func extractConfiguredURL(from stremioURL: String) -> String {
            StremioClient.normalizedConfiguredURL(from: stremioURL)
        }
    }
}
#endif
