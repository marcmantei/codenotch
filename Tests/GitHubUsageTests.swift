import Combine
import XCTest
@testable import Codenotch

final class GitHubUsageTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-09-30T23:30:00Z")!
    private func account(_ report: GitHubUsageAccount.Report = .enterprise) -> GitHubUsageAccount {
        var account = GitHubUsageAccount()
        account.name = "Work"
        account.owner = "example-enterprise"
        account.report = report
        return account
    }

    func testBillingURLsUseUTCMonthAndAllEnterpriseCostCenters() throws {
        for (report, path) in [(GitHubUsageAccount.Report.enterprise, "enterprises"), (.organization, "organizations"), (.user, "users")] {
            let url = try account(report).requestURL(now: date)
            XCTAssertEqual(url.host, "api.github.com")
            XCTAssertEqual(url.path, "/\(path)/example-enterprise/settings/billing/usage/summary")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "year" }?.value, "2026")
            XCTAssertEqual(query.first { $0.name == "month" }?.value, "9")
            XCTAssertEqual(query.first { $0.name == "product" }?.value, "Actions")
            XCTAssertFalse(query.contains { $0.name == "cost_center_id" })
        }
    }

    func testHostAndSlugCannotRedirectCredentials() throws {
        var config = account()
        for host in ["evil.example", "github.com.evil.example", "https://github.com", "../github.com", "api.company.ghe.com"] {
            config.host = host
            XCTAssertThrowsError(try config.requestURL(now: date))
        }
        config.host = "company.ghe.com"
        XCTAssertEqual(try config.requestURL(now: date).host, "api.company.ghe.com")
        config.owner = "company/../other?month=1"
        XCTAssertThrowsError(try config.requestURL(now: date))
    }

    func testNamedCLIAccountIsExplicitAndNeverSwitches() {
        var config = account()
        config.cliUsername = "work_user"
        XCTAssertEqual(GitHubUsageCredentials.cliArguments(config),
                       ["auth", "token", "--hostname", "github.com", "--user", "work_user"])
    }

    func testBillingSeparatesMinutesStorageOtherProductsAndDiscounts() throws {
        let data = Data(#"{"usageItems":[{"product":"Actions","unitType":"minutes","grossQuantity":120.5,"netAmount":0},{"product":"actions","unitType":"minutes","grossQuantity":30,"netAmount":0.24},{"product":"Actions","unitType":"gb-hours","grossQuantity":9000,"netAmount":2},{"product":"Copilot","unitType":"requests","grossQuantity":99,"netAmount":50}]}"#.utf8)
        let windows = try GitHubActionsUsage.windows(from: data, now: date)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].usedText, 150.5.formatted(.number.precision(.fractionLength(0...2))) + " min")
        XCTAssertEqual(windows[1].usedText, 2.24.formatted(.currency(code: "USD")))
        XCTAssertNil(windows[0].usedFraction)
        XCTAssertNil(windows[1].usedFraction)
        XCTAssertEqual(windows[0].summary, windows[0].usedText)
        XCTAssertEqual(windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
    }

    func testEmptyUsageIsZeroButMalformedDataIsNot() throws {
        XCTAssertEqual(try GitHubActionsUsage.windows(from: Data(#"{"usageItems":[]}"#.utf8), now: date)[0].usedText, "0 min")
        for invalid in ["{}", #"{"message":"denied"}"#, #"{"usageItems":[{"product":"Actions","unitType":"minutes","grossQuantity":-1,"netAmount":0}]}"#, #"{"usageItems":[{"product":"Actions"}]}"#] {
            XCTAssertThrowsError(try GitHubActionsUsage.windows(from: Data(invalid.utf8), now: date))
        }
    }

    func testAllowanceCreatesPercentageBarAndMinutePopup() throws {
        let data = Data(#"{"usageItems":[{"product":"Actions","unitType":"minutes","grossQuantity":31539,"netAmount":0}]}"#.utf8)
        let windows = try GitHubActionsUsage.windows(from: data, now: date, allowance: 50_000)
        let snapshot = ProviderSnapshot(id: "work", displayName: "Work", glyph: .github,
                                        fidelity: .official, status: .ok, windows: windows, headlineID: "actions-minutes")
        XCTAssertEqual(snapshot.headlineText, "63%")
        XCTAssertEqual(try XCTUnwrap(snapshot.ringFraction), 0.63078, accuracy: 0.000001)
        XCTAssertFalse(windows[0].prefersUsedText)
        XCTAssertEqual(windows[0].detail, "\(31539.formatted()) / \(50000.formatted()) min")
        XCTAssertEqual(windows[1].usedText, "\(18461.formatted()) min")
        XCTAssertEqual(windows[0].resetTimeFormat, .remaining)
        XCTAssertEqual(ResetCopy.text(for: try XCTUnwrap(windows[0].resetsAt), now: date,
                                      format: try XCTUnwrap(windows[0].resetTimeFormat), locale: Locale(identifier: "en")), "Resets in 30 min")
        XCTAssertEqual(snapshot.compactRowCount, 2)
        let archived = try JSONDecoder().decode([LimitWindow].self, from: JSONEncoder().encode(windows))
        XCTAssertEqual(archived, windows)
    }

    func testOverAllowanceKeepsFullPercentageAndShowsOverage() throws {
        let data = Data(#"{"usageItems":[{"product":"Actions","unitType":"minutes","grossQuantity":5049,"netAmount":18.294}]}"#.utf8)
        let windows = try GitHubActionsUsage.windows(from: data, now: date, allowance: 2_000)
        let snapshot = ProviderSnapshot(id: "personal", displayName: "Personal", glyph: .github,
                                        fidelity: .official, status: .ok, windows: windows, headlineID: "actions-minutes")
        XCTAssertEqual(snapshot.headlineText, "252%")
        XCTAssertEqual(windows[1].usedText, "0 min")
        XCTAssertEqual(windows[2].id, "actions-overage")
        XCTAssertEqual(windows[2].usedText, "\(3049.formatted()) min")
        XCTAssertEqual(windows[3].usedText, 18.294.formatted(.currency(code: "USD")))
        XCTAssertEqual(snapshot.compactRowCount, 3)
    }

    func testAllowancesAreIndependentAndOlderAccountsStillDecode() throws {
        var work = account()
        var personal = account(.user)
        XCTAssertEqual(work.effectiveMinutesAllowance, 50_000)
        XCTAssertEqual(personal.effectiveMinutesAllowance, 2_000)
        personal.monthlyMinutesAllowance = 3_000
        XCTAssertEqual(personal.effectiveMinutesAllowance, 3_000)
        XCTAssertEqual(work.effectiveMinutesAllowance, 50_000)
        let encoded = try JSONEncoder().encode(work)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("monthlyMinutesAllowance"))
        XCTAssertEqual(try JSONDecoder().decode(GitHubUsageAccount.self, from: encoded).effectiveMinutesAllowance, 50_000)
        for invalid in [0.0, -1, 0.5, Double.infinity, Double.nan] {
            work.monthlyMinutesAllowance = invalid
            XCTAssertNotNil(work.validationMessage)
            XCTAssertThrowsError(try GitHubActionsUsage.windows(from: Data(#"{"usageItems":[]}"#.utf8), now: date, allowance: invalid))
        }
    }

    func testZeroUsageAndUTCMonthRolloverIncludingLeapYear() throws {
        for (now, next) in [("2026-12-31T23:59:00Z", "2027-01-01T00:00:00Z"),
                            ("2028-02-20T10:00:00Z", "2028-03-01T00:00:00Z")] {
            let formatter = ISO8601DateFormatter()
            let windows = try GitHubActionsUsage.windows(from: Data(#"{"usageItems":[]}"#.utf8),
                                                       now: formatter.date(from: now)!, allowance: 2_000)
            XCTAssertEqual(windows[0].usedFraction, 0)
            XCTAssertEqual(windows[0].resetsAt, formatter.date(from: next))
            XCTAssertEqual(windows[1].usedText, "\(2000.formatted()) min")
            XCTAssertFalse(windows.contains { $0.id == "actions-overage" })
        }
    }

    private func session(status: Int = 200, headers: [String: String] = [:], data: Data = Data(#"{"usageItems":[]}"#.utf8)) -> URLSession {
        GitHubUsageEndpoint.reset(status: status, headers: headers, data: data)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubUsageEndpoint.self]
        return URLSession(configuration: config)
    }

    func testEachDisplayUsesOnlyItsOwnCredential() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let first = account()
        var second = account(.user)
        second.owner = "private-user"
        let work = GitHubUsageProvider(account: first, session: session, now: { self.date }, credentialLoader: { "work-test-token" })
        let personal = GitHubUsageProvider(account: second, session: session, now: { self.date }, credentialLoader: { "private-test-token" })
        let a = try await work.fetchSnapshot()
        let b = try await personal.fetchSnapshot()
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.windows[0].usedFraction, 0)
        XCTAssertEqual(b.windows[0].usedFraction, 0)
        XCTAssertEqual(a.windows[1].usedText, "\(50000.formatted()) min")
        XCTAssertEqual(b.windows[1].usedText, "\(2000.formatted()) min")
        XCTAssertEqual(GitHubUsageEndpoint.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer work-test-token", "Bearer private-test-token"])
        XCTAssertEqual(GitHubUsageEndpoint.requests[0].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testPermissionFailureDoesNotPretendToBeZeroUsage() async {
        for status in [403, 404] {
            let session = session(status: status)
            defer { session.invalidateAndCancel() }
            let provider = GitHubUsageProvider(account: account(), session: session, credentialLoader: { "test" })
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("expected permission failure")
            } catch UsageProviderError.apiError(let message) {
                XCTAssertTrue(message.contains("billing"))
            } catch { XCTFail("unexpected \(error)") }
        }
    }

    func testAuthenticationAndRateLimitsHaveDistinctOutcomes() async {
        for (status, headers) in [(401, [String: String]()), (429, ["Retry-After": "120"]), (403, ["X-RateLimit-Remaining": "0", "Retry-After": "120"])] {
            let session = session(status: status, headers: headers)
            defer { session.invalidateAndCancel() }
            let provider = GitHubUsageProvider(account: account(), session: session, credentialLoader: { "test" })
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("expected failure")
            } catch UsageProviderError.needsAuth { XCTAssertEqual(status, 401) }
            catch UsageProviderError.rateLimited(let retry) { XCTAssertEqual(retry, 120) }
            catch { XCTFail("unexpected \(error)") }
        }
    }

    func testRateLimitWaitDoesNotSendAnotherRequest() async {
        let session = session(status: 429, headers: ["Retry-After": "120"])
        defer { session.invalidateAndCancel() }
        let date = self.date
        let provider = GitHubUsageProvider(account: account(), session: session, now: { date }, credentialLoader: { "test" })
        for _ in 0..<2 {
            do {
                _ = try await provider.fetchSnapshot()
                XCTFail("expected rate limit")
            } catch UsageProviderError.rateLimited(let delay) { XCTAssertEqual(delay, 120) }
            catch { XCTFail("unexpected error") }
        }
        XCTAssertEqual(GitHubUsageEndpoint.requests.count, 1)
    }

    func testCopilotDisplayUsesExistingQuotaParser() async throws {
        let data = Data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":270,"unlimited":false}}}"#.utf8)
        let session = session(data: data)
        defer { session.invalidateAndCancel() }
        let provider = GitHubUsageProvider(account: account(.copilot), session: session, credentialLoader: { "test" })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.windows.first?.usedFraction, 0.1)
        XCTAssertEqual(GitHubUsageEndpoint.requests.first?.url?.path, "/copilot_internal/user")
    }
}

@MainActor
final class GitHubUsageSettingsTests: XCTestCase {
    func testAccountsPersistSeparatelyWithoutTokens() throws {
        let name = "GitHubUsageSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = Preferences(defaults: defaults)
        var first = GitHubUsageAccount()
        first.name = "Private"
        var second = GitHubUsageAccount()
        second.name = "Enterprise"
        preferences.saveGitHubUsageAccount(first)
        preferences.saveGitHubUsageAccount(second)
        XCTAssertEqual(Preferences.storedGitHubUsageAccounts(defaults: defaults), [first, second])
        XCTAssertTrue(preferences.isConnected(first.providerID))
        XCTAssertTrue(preferences.isConnected(second.providerID))
        let encoded = try JSONSerialization.jsonObject(with: defaults.data(forKey: "githubUsageAccounts")!) as! [[String: Any]]
        XCTAssertFalse(encoded.contains { $0["token"] != nil })
    }

    func testRemovingDisplaysClearsReadingsArchiveAndProviderList() async throws {
        let name = "GitHubUsageStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let archive = UsageArchive(defaults: defaults)
        let provider = GitHubUsageProbe()
        let store = UsageStore(providers: [provider], archive: archive)
        let fetched = expectation(description: "Fetched")
        let subscription = store.$snapshots.filter { $0.contains { $0.id == provider.id && $0.hasReading } }
            .prefix(1).sink { _ in fetched.fulfill() }
        store.refreshNow()
        await fulfillment(of: [fetched], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertNotNil(archive.load()[provider.id])
        store.registerGitHubUsageProviders([])
        XCTAssertFalse(store.knownIDs.contains(provider.id))
        XCTAssertNil(archive.load()[provider.id])
        XCTAssertFalse(store.providerSummaries.contains { $0.id == provider.id })
        store.stop()
    }

    func testForkNeverStartsOriginalUpdaterEvenOnManualCheck() {
        let updater = Updater()
        XCTAssertTrue(updater.isForkBuild)
        updater.automatic = true
        XCTAssertFalse(updater.automatic)
        updater.start()
        updater.checkNow()
        XCTAssertEqual(updater.outcome, .failed(updater.forkUpdateMessage))
        XCTAssertNil(updater.pending)
    }
}

private struct GitHubUsageProbe: UsageProvider {
    let id = "github-usage-test"
    let displayName = "Test"
    let glyph = ProviderGlyph.copilot
    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: displayName, glyph: glyph, fidelity: .official,
                         status: .ok, windows: [LimitWindow(id: "test", label: "Test", used: 10)], headlineID: "test")
    }
}

private final class GitHubUsageEndpoint: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var headers: [String: String] = [:]
    private static var data = Data()
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int, headers: [String: String], data: Data) {
        lock.withLock {
            self.status = status; self.headers = headers; self.data = data; recorded = []
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.status, Self.headers, Self.data)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
