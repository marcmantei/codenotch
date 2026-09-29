import Foundation
import Security

enum GitHubUsageCredentials {
    static let service = "com.marc.codenotch.github-usage"

    static func save(_ token: String, account: GitHubUsageAccount) -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        return KeychainItem.store(service: service, account: account.id, value: token)
    }

    static func delete(account: GitHubUsageAccount) {
        KeychainItem.delete(service: service, account: account.id)
    }

    static func load(_ account: GitHubUsageAccount) throws -> String {
        if account.authentication == .cli { return try cliToken(account) }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.id,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { throw UsageProviderError.needsAuth }
        guard status == errSecSuccess else { throw UsageProviderError.accessDenied }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { throw UsageProviderError.needsAuth }
        return token
    }

    static func cliArguments(_ account: GitHubUsageAccount) -> [String] {
        ["auth", "token", "--hostname", account.host, "--user", account.cliUsername]
    }

    private static func cliToken(_ account: GitHubUsageAccount) throws -> String {
        guard let executable = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageProviderError.apiError(L10n.t("Install GitHub CLI or use a separate token."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = cliArguments(account)
        var environment = ProcessInfo.processInfo.environment
        // A global GH_TOKEN must never override the explicitly selected account.
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw UsageProviderError.needsAuth }
        return token
    }
}

actor GitHubUsageProvider: UsageProvider {
    nonisolated let configuration: GitHubUsageAccount
    nonisolated var id: String { configuration.providerID }
    nonisolated var displayName: String { configuration.name }
    nonisolated var glyph: ProviderGlyph { configuration.report == .copilot ? .copilot : .github }
    private let session: URLSession
    private let credentialLoader: @Sendable () throws -> String
    private let credentials = CredentialCache<String> { _ in false }
    private let now: @Sendable () -> Date
    private var retryAt: Date?

    init(account: GitHubUsageAccount, session: URLSession = .shared,
         now: @escaping @Sendable () -> Date = Date.init,
         credentialLoader: (@Sendable () throws -> String)? = nil) {
        self.configuration = account
        self.session = session
        self.now = now
        self.credentialLoader = credentialLoader ?? { try GitHubUsageCredentials.load(account) }
    }

    nonisolated var signInRoute: SignInRoute {
        .guidance(L10n.t("Configure this display in Settings → Accounts → GitHub. Your terminal login stays unchanged."))
    }
    nonisolated func account() -> ProviderAccount? {
        ProviderAccount(label: configuration.report == .copilot ? configuration.name : configuration.owner,
                        plan: configuration.report.title, source: configuration.host,
                        manageURL: URL(string: "https://\(configuration.host)/settings/billing"))
    }
    nonisolated func forgetCachedCredential() { credentials.forget() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let date = now()
        if let retryAt, retryAt > date {
            throw UsageProviderError.rateLimited(retryAfter: retryAt.timeIntervalSince(date))
        }
        var request = URLRequest(url: try configuration.requestURL(now: date))
        let token = try credentials.value(reload: credentialLoader)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Codenotch", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageProviderError.badResponse(status: 0) }
        if http.statusCode == 429 || (http.statusCode == 403 &&
            (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.value(forHTTPHeaderField: "Retry-After") != nil)) {
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init)
            let delay = max(60, retry ?? reset.map { $0 - date.timeIntervalSince1970 } ?? 60)
            retryAt = date.addingTimeInterval(delay)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        if http.statusCode == 401 {
            credentials.forget()
            throw UsageProviderError.needsAuth
        }
        if http.statusCode == 403 || http.statusCode == 404 {
            throw UsageProviderError.apiError(L10n.t("GitHub denied this report. Check the account or enterprise slug, billing permissions and SSO authorization in GitHub settings."))
        }
        guard (200..<300).contains(http.statusCode) else { throw UsageProviderError.badResponse(status: http.statusCode) }
        retryAt = nil
        let windows = try configuration.report == .copilot
            ? GitHubCopilotUsage.windows(from: data)
            : GitHubActionsUsage.windows(from: data, now: date, allowance: configuration.effectiveMinutesAllowance)
        return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                fidelity: .official, status: .ok, windows: windows,
                                headlineID: windows.first?.id,
                                plan: configuration.report == .copilot ? GitHubCopilotUsage.plan(from: data) : configuration.report.title)
    }
}

enum GitHubActionsUsage {
    private struct Report: Decodable { let usageItems: [Item] }
    private struct Item: Decodable {
        let product: String
        let unitType: String
        let grossQuantity: Double
        let netAmount: Double
    }

    static func windows(from data: Data, now: Date, allowance: Double? = nil) throws -> [LimitWindow] {
        let report: Report
        do { report = try JSONDecoder().decode(Report.self, from: data) }
        catch { throw UsageProviderError.badResponse(status: 0) }
        let actions = report.usageItems.filter { $0.product.lowercased() == "actions" }
        guard actions.allSatisfy({ $0.grossQuantity.isFinite && $0.grossQuantity >= 0 && $0.netAmount.isFinite }) else {
            throw UsageProviderError.badResponse(status: 0)
        }
        let minutes = actions.filter { $0.unitType.lowercased() == "minutes" }.reduce(0) { $0 + $1.grossQuantity }
        let cost = actions.reduce(0) { $0 + $1.netAmount }
        guard minutes.isFinite, cost.isFinite else { throw UsageProviderError.badResponse(status: 0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cycle = calendar.dateInterval(of: .month, for: now)!
        // Billing sums runner minutes, not storage quantities. The user supplies
        // the allowance; this ratio does not reproduce GitHub's SKU pricing.
        func minutesText(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(0...2))) + " min"
        }
        let minuteText = minutesText(minutes)
        var windows: [LimitWindow] = []
        if let allowance {
            guard allowance.isFinite, allowance >= 1 else {
                throw UsageProviderError.apiError(L10n.t("Enter a monthly allowance of at least 1 minute."))
            }
            windows.append(LimitWindow(id: "actions-minutes", label: L10n.t("Actions · Month"),
                                       usedFraction: minutes / allowance, usedText: minuteText,
                                       detail: "\(minutes.formatted(.number.precision(.fractionLength(0...2)))) / \(minutesText(allowance))",
                                       resetsAt: cycle.end, duration: cycle.duration, resetTimeFormat: .remaining))
            windows.append(LimitWindow(id: "actions-remaining", label: L10n.t("Minutes remaining"),
                                       usedText: minutesText(max(0, allowance - minutes))))
            if minutes > allowance {
                windows.append(LimitWindow(id: "actions-overage", label: L10n.t("Minutes over allowance"),
                                           usedText: minutesText(minutes - allowance)))
            }
        } else {
            windows.append(LimitWindow(id: "actions-minutes", label: L10n.t("Actions minutes · Month"),
                                       usedText: minuteText, resetsAt: cycle.end,
                                       duration: cycle.duration, prefersUsedText: true))
        }
        windows.append(LimitWindow(id: "actions-cost", label: L10n.t("Actions net cost · Month"),
                                   usedText: cost.formatted(.currency(code: "USD")),
                                   resetsAt: cycle.end, duration: cycle.duration, prefersUsedText: true))
        return windows
    }
}
