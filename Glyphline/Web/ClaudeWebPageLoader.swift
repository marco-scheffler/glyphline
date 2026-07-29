import Foundation
import WebKit

/// Loads one URL in a throwaway `WKWebView` and hands back the document text and
/// the HTTP status that came with it.
///
/// Single-shot on purpose. The two things that go wrong with a web view used for
/// fetching are that it hangs and that it leaks, and both are far easier to rule
/// out when one instance serves exactly one navigation:
///
/// - **It cannot hang.** Exactly one continuation covers the navigation *and* the
///   body read, and every exit resumes it: finished, navigation failure, content
///   the view cannot display, content process death, timeout, cancellation. A
///   timer is armed before the load starts and is only disarmed by settling, so
///   even a path nobody anticipated is bounded. This matters because
///   `collectRateWindows` runs accounts sequentially — one view waiting on a
///   Cloudflare challenge would otherwise block every other account forever.
/// - **It cannot outlive its fetch.** `tearDown()` stops the load, drops the
///   delegate and drops this type's reference to the view. Callers run it from a
///   `defer`, so it covers success, failure, timeout and cancellation alike. A
///   view that outlives its fetch is a web content process that outlives it too,
///   and three of those per sync tick is hundreds of processes after a day.
///   One caveat, since the guarantee is about *this* reference: a body read that
///   is still suspended holds its own strong reference for as long as
///   `evaluateJavaScript` takes to come back, so the view is released on that
///   call's completion rather than on the `tearDown()` call itself.
///
/// Holds no cookie and no session key: the `WKWebsiteDataStore` it is handed owns
/// those, and nothing here reads them. The body it returns is passed straight to
/// `ClaudeWebResponseClassifier` and never to a message or a log.
@MainActor
final class ClaudeWebPageLoader: NSObject {
    struct Outcome: Sendable {
        var body: String
        var statusCode: Int?
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Outcome, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var statusCode: Int?
    private var isSettled = false
    private var isTornDown = false

    init(dataStore: WKWebsiteDataStore) {
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view
    }

    /// Navigates to `url` and returns the document text once it has loaded.
    ///
    /// Throws `RateWindowSourceError` for a failure that has a name, and
    /// `CancellationError` when the surrounding task was cancelled — which is a
    /// different thing from "the provider is unreachable" and must not be
    /// reported as one.
    func load(_ url: URL, timeout: Duration) async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, any Error>) in
                // `self.continuation == nil` enforces single-shot rather than
                // merely documenting it. A second `load` would otherwise
                // overwrite the first continuation and orphan it: a permanent
                // hang for that caller plus a leaked checked continuation.
                guard !isTornDown, !isSettled, self.continuation == nil, let webView else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.continuation = continuation
                armTimeout(timeout)
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.settle(.failure(CancellationError()))
            }
        }
    }

    /// Releases the web view. Idempotent, and safe to call whether or not a load
    /// is in flight.
    func tearDown() {
        isTornDown = true
        settle(.failure(CancellationError()))

        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView = nil
    }

    private func armTimeout(_ timeout: Duration) {
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                // Disarmed by `settle`. The outcome has already been decided.
                return
            }
            self?.settle(.failure(RateWindowSourceError.transportFailure))
        }
    }

    /// The single exit. Later callers are ignored, so a delegate callback that
    /// arrives after a timeout cannot resume a continuation twice.
    private func settle(_ result: Result<Outcome, any Error>) {
        guard !isSettled else { return }
        isSettled = true

        timeoutTask?.cancel()
        timeoutTask = nil

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    /// Reads the document exactly once, with the single `evaluateJavaScript` the
    /// design calls for. The timeout stays armed across this, so a read that
    /// never comes back is bounded like everything else.
    private func readBody() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let webView = self.webView else {
                self.settle(.failure(RateWindowSourceError.transportFailure))
                return
            }

            do {
                let value = try await webView.evaluateJavaScript("document.body.innerText")
                guard let text = value as? String else {
                    return self.settle(.failure(RateWindowSourceError.unreadableResponse))
                }
                self.settle(.success(Outcome(body: text, statusCode: self.statusCode)))
            } catch {
                self.settle(.failure(RateWindowSourceError.unreadableResponse))
            }
        }
    }
}

extension ClaudeWebPageLoader: WKNavigationDelegate {
    /// The status code arrives here and nowhere else.
    ///
    /// `decisionHandler` must carry `@MainActor @Sendable` to match the
    /// declaration exactly. Without them this is merely a *similar* method rather
    /// than the delegate requirement, WebKit never calls it, and every response
    /// reaches the classifier with a `nil` status — which it correctly reads as
    /// `transportFailure`. The feature would fail completely, in a way that looks
    /// like the network being down. The compiler says so only as a
    /// "nearly matches optional requirement" warning, so that warning is
    /// load-bearing here.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        statusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode

        // A response the view cannot render would otherwise become a download,
        // which writes the body to disk and never finishes the navigation.
        guard navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel)
            settle(.failure(RateWindowSourceError.unreadableResponse))
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        readBody()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(RateWindowSourceError.transportFailure))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        settle(.failure(RateWindowSourceError.transportFailure))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        settle(.failure(RateWindowSourceError.transportFailure))
    }
}
