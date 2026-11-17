import Foundation
import WebKit

/// One API organisation's credit, or why it could not be read.
struct ConsoleCreditReading: Equatable, Sendable {
    var organization: ConsoleOrganization
    var result: Result<ConsoleCreditBalance, RateWindowSourceError>
}

protocol ConsoleCreditFetching: Sendable {
    /// Throws only `CancellationError`; every other failure is a reading.
    func fetchCredits(account: Account) async throws -> [ConsoleCreditReading]
}

/// Reads the prepaid Console credit of each connected API organisation through
/// the account's own logged-in session, the way `ClaudeWebQuotaSource` reads
/// quota. No part of a body reaches a message.
@MainActor
struct ConsoleCreditSource: ConsoleCreditFetching {
    var sessionStore: ClaudeWebSessionStore
    var now: @Sendable () -> Date
    var timeout: Duration

    init(
        sessionStore: ClaudeWebSessionStore = ClaudeWebSessionStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        timeout: Duration = .seconds(30)
    ) {
        self.sessionStore = sessionStore
        self.now = now
        self.timeout = timeout
    }

    func fetchCredits(account: Account) async throws -> [ConsoleCreditReading] {
        var readings: [ConsoleCreditReading] = []
        // Sequential and in stored order, so the numbering on the card is stable.
        for organization in account.consoleOrganizations {
            let result = try await fetchBalance(account: account, organizationID: organization.id)
            readings.append(ConsoleCreditReading(organization: organization, result: result))
        }
        return readings
    }

    private func fetchBalance(
        account: Account,
        organizationID: String
    ) async throws -> Result<ConsoleCreditBalance, RateWindowSourceError> {
        guard let creditsURL = ClaudeWebEndpoints.consoleCredits(organizationID: organizationID),
              let spendURL = ClaudeWebEndpoints.consoleCurrentSpend(organizationID: organizationID)
        else {
            return .failure(.unexpectedResponseShape)
        }

        let creditsData: Data
        switch try await load(creditsURL, account: account, classify: ClaudeWebResponseClassifier.classifyConsoleCredits) {
        case .failure(let error): return .failure(error)
        case .success(let data): creditsData = data
        }
        guard let credits = try? ConsoleCreditsResponse.decode(creditsData) else {
            return .failure(.unexpectedResponseShape)
        }

        // Spend is optional: without it the month line is missing, the balance
        // is still true.
        var spend: ConsoleCurrentSpendResponse?
        if case .success(let data) = try await load(
            spendURL, account: account, classify: ClaudeWebResponseClassifier.classifyConsoleSpend
        ) {
            spend = try? ConsoleCurrentSpendResponse.decode(data)
        }

        guard let balance = ConsoleCreditBalance(credits: credits, spend: spend, now: now()) else {
            return .failure(.unexpectedResponseShape)
        }
        return .success(balance)
    }

    private func load(
        _ url: URL,
        account: Account,
        classify: (String, Int?) -> Result<Data, RateWindowSourceError>
    ) async throws -> Result<Data, RateWindowSourceError> {
        let loader = ClaudeWebPageLoader(dataStore: sessionStore.dataStore(for: account.id))
        // Every exit releases the view: success, failure, timeout, cancellation.
        defer { loader.tearDown() }

        let outcome: ClaudeWebPageLoader.Outcome
        do {
            outcome = try await loader.load(url, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RateWindowSourceError {
            return .failure(error)
        } catch {
            return .failure(.transportFailure)
        }
        return classify(outcome.body, outcome.statusCode)
    }
}
