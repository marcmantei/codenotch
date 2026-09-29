import Foundation

/// Configuration contains no secrets. Each display has its own keychain item,
/// even when two displays report on the same GitHub account.
struct GitHubUsageAccount: Codable, Equatable, Identifiable, Sendable {
    enum Report: String, Codable, CaseIterable, Identifiable {
        case copilot, user, organization, enterprise
        var id: String { rawValue }
        var title: String {
            switch self {
            case .copilot: return L10n.t("Copilot · Personal quota")
            case .user: return L10n.t("Actions · Personal account")
            case .organization: return L10n.t("Actions · Organization")
            case .enterprise: return L10n.t("Actions · Enterprise")
            }
        }
        var pathComponent: String {
            switch self {
            case .copilot: return ""
            case .user: return "users"
            case .organization: return "organizations"
            case .enterprise: return "enterprises"
            }
        }
    }
    enum Authentication: String, Codable, CaseIterable, Identifiable {
        case token, cli
        var id: String { rawValue }
        var title: String { self == .token ? L10n.t("Separate token") : L10n.t("Named GitHub CLI account") }
    }

    var id = UUID().uuidString
    var name = ""
    var report: Report = .enterprise
    var owner = ""
    var host = "github.com"
    var authentication: Authentication = .token
    var cliUsername = ""
    // Changes when a token is replaced, invalidating in-flight reads and caches.
    var credentialRevision = UUID().uuidString

    var providerID: String { "github-usage-\(id)" }
    var apiHost: String { host == "github.com" ? "api.github.com" : "api.\(host)" }
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.t("Enter a display name.")
        }
        let validHost = host == "github.com" || host.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.ghe\.com$"#, options: .regularExpression) != nil
        if !validHost { return L10n.t("Use github.com or your enterprise's subdomain.ghe.com host.") }
        if report == .copilot && host != "github.com" {
            return L10n.t("Copilot quota reports currently support github.com only.")
        }
        if report != .copilot && !Self.isSlug(owner) {
            return L10n.t("Enter the account, organization or enterprise slug from its GitHub URL.")
        }
        if authentication == .cli && !Self.isSlug(cliUsername) {
            return L10n.t("Enter the exact username already signed in to GitHub CLI.")
        }
        return nil
    }
    private static func isSlug(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    func requestURL(now: Date) throws -> URL {
        if let message = validationMessage { throw UsageProviderError.apiError(message) }
        var url = URLComponents()
        url.scheme = "https"
        url.host = apiHost
        if report == .copilot {
            url.path = "/copilot_internal/user"
        } else {
            url.path = "/\(report.pathComponent)/\(owner)/settings/billing/usage/summary"
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let date = calendar.dateComponents([.year, .month], from: now)
            // Summary includes ALL enterprise cost centers when no cost center
            // is specified. The older /usage endpoint does not.
            url.queryItems = [URLQueryItem(name: "year", value: String(date.year!)),
                              URLQueryItem(name: "month", value: String(date.month!)),
                              URLQueryItem(name: "product", value: "Actions")]
        }
        guard let result = url.url else { throw UsageProviderError.badResponse(status: 0) }
        return result
    }
}
