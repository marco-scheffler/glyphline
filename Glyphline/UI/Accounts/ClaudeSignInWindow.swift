import AppKit
import WebKit

/// The visible browser window where the user establishes a claude.ai session for
/// one account.
///
/// The app fills nothing in and reads nothing out. The user signs in normally,
/// WebKit keeps the session in that account's own data store, and no cookie or
/// session key is ever handled here.
///
/// **Success is detected by doing the thing.** When the user says they are signed
/// in, the window runs the same two navigations the steady state runs: the
/// organisations list, then the usage endpoint for the organisation it selected.
/// JSON from both means the session works. Nothing is matched on a URL or on page
/// content — that is guesswork that breaks on a redesign, and it would let the
/// sign-in check and real use drift apart.
@MainActor
final class ClaudeSignInWindow: NSObject {
    enum Outcome: Sendable, Equatable {
        /// Signed in, and the subscription's organisation was resolved *and*
        /// proven to answer the usage endpoint.
        case signedIn(organizationID: String)
        /// The session could not be used. Nothing was resolved and nothing should
        /// be persisted.
        case failed(RateWindowSourceError)
        /// The user closed the window without completing.
        case cancelled
    }

    private static let promptText = "Sign in to Claude in this window, then choose Continue."
    private static let checkingText = "Checking your session…"
    private static let continueTitle = "Continue"

    private let dataStore: WKWebsiteDataStore
    private let timeout: Duration

    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private var continueButton: NSButton?
    private var verification: Task<Void, Never>?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var isSettled = false

    /// What closing the window will report. Stays `.cancelled` until a check
    /// establishes something the user cannot retry their way out of.
    private var pendingOutcome: Outcome = .cancelled

    init(account: Account, sessionStore: ClaudeWebSessionStore, timeout: Duration = .seconds(30)) {
        // One data store instance is shared by the visible view and by every
        // check, so a session established a moment ago is visible immediately
        // rather than after WebKit gets around to flushing it.
        dataStore = sessionStore.dataStore(for: account.id)
        self.timeout = timeout
        super.init()
    }

    /// Shows the window and returns once the user has completed or closed it.
    ///
    /// Cancelling the awaiting task tears the window down and reports
    /// `.cancelled`, exactly as `ClaudeWebPageLoader.load` does. Without this, a
    /// caller presenting from a SwiftUI `.task` or a sheet-scoped task would
    /// leave the continuation unresumed when the view goes away — the awaiting
    /// task suspended forever, and the window, its `WKWebView` and its web
    /// content process alive until the user notices the orphan and closes it by
    /// hand. Visible rather than silent, but still the "cancellation leaves a
    /// browser process" case this whole task exists to eliminate.
    func present() async -> Outcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                // `self.continuation == nil` enforces single-shot rather than
                // merely documenting it: a second `present` would otherwise
                // overwrite the first continuation and orphan it.
                guard !isSettled, self.continuation == nil else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                self.continuation = continuation
                buildWindow()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.settle(.cancelled)
            }
        }
    }

    // MARK: - Verification

    @objc
    private func continueTapped() {
        guard verification == nil else { return }

        continueButton?.isEnabled = false
        statusLabel?.stringValue = Self.checkingText

        verification = Task { @MainActor [weak self] in
            await self?.verify()
            self?.verification = nil
        }
    }

    private func verify() async {
        let organizations: [ClaudeOrganization]
        switch await fetch(ClaudeWebEndpoints.organizations, classify: ClaudeWebResponseClassifier.classifyOrganizations) {
        case .failure(let error):
            return report(error)
        case .success(let data):
            guard let decoded = try? ClaudeOrganizationsResponse.decode(data) else {
                return report(.unreadableResponse)
            }
            organizations = decoded
        }

        // By capability, never by position. A login with no Max subscription has
        // no organisation whose usage figures would mean anything, and picking
        // one anyway would report a number that is quietly the wrong number.
        guard let organizationID = ClaudeOrganizationsResponse.subscriptionOrganizationID(in: organizations),
              let usageURL = ClaudeWebEndpoints.usage(organizationID: organizationID)
        else {
            return report(.notAvailable)
        }

        switch await fetch(usageURL, classify: ClaudeWebResponseClassifier.classify) {
        case .failure(let error):
            report(error)
        case .success:
            finish(.signedIn(organizationID: organizationID))
        }
    }

    /// One navigation in a hidden view sharing the visible window's session, run
    /// through the same loader and the same classifier the steady state uses.
    private func fetch(
        _ url: URL,
        classify: (String, Int?) -> Result<Data, RateWindowSourceError>
    ) async -> Result<Data, RateWindowSourceError> {
        let loader = ClaudeWebPageLoader(dataStore: dataStore)
        defer { loader.tearDown() }

        do {
            let outcome = try await loader.load(url, timeout: timeout)
            return classify(outcome.body, outcome.statusCode)
        } catch let error as RateWindowSourceError {
            return .failure(error)
        } catch {
            return .failure(.transportFailure)
        }
    }

    /// Shows why the check did not pass, using the error's own message and
    /// nothing from the response.
    private func report(_ error: RateWindowSourceError) {
        statusLabel?.stringValue = error.message

        switch error {
        case .notAvailable:
            // Retrying cannot turn a login without a Max subscription into one.
            pendingOutcome = .failed(.notAvailable)
        default:
            continueButton?.isEnabled = true
        }
    }

    // MARK: - Window

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.webView = webView

        let statusLabel = NSTextField(labelWithString: Self.promptText)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.statusLabel = statusLabel

        let continueButton = NSButton(title: Self.continueTitle, target: self, action: #selector(continueTapped))
        continueButton.keyEquivalent = "\r"
        self.continueButton = continueButton

        let bar = NSStackView(views: [statusLabel, NSView(), continueButton])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let root = NSStackView(views: [webView, bar])
        root.orientation = .vertical
        root.spacing = 0
        root.distribution = .fill

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        // Held here rather than by AppKit, so closing cannot over-release it.
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.delegate = self
        self.window = window

        webView.load(URLRequest(url: ClaudeWebEndpoints.signIn))

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(_ outcome: Outcome) {
        settle(outcome)
    }

    /// The single exit. Tears the window and both web views down before resuming,
    /// so no browser process outlives the sign-in.
    private func settle(_ outcome: Outcome) {
        guard !isSettled else { return }
        isSettled = true

        verification?.cancel()
        verification = nil

        if let webView {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webView = nil

        if let window {
            // Cleared first: `close()` must not re-enter through the delegate.
            window.delegate = nil
            window.contentView = nil
            window.close()
        }
        window = nil

        statusLabel = nil
        continueButton = nil

        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

extension ClaudeSignInWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settle(pendingOutcome)
    }
}
