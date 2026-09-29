import SwiftUI

struct GitHubUsageSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var editing: GitHubUsageAccount?
    @State private var deleting: GitHubUsageAccount?

    var body: some View {
        Form {
            Section {
                Text(L10n.t("Add separate displays for private and work accounts. Each display has its own credentials; your active GitHub CLI login stays unchanged."))
                    .foregroundStyle(.secondary)
                Button(L10n.t("Add GitHub display")) { editing = GitHubUsageAccount() }
                ForEach(preferences.githubUsageAccounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name).fontWeight(.medium)
                            Text("\(account.report.title) · \(account.owner.isEmpty ? account.host : account.owner)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.t("Edit")) { editing = account }
                        Button(role: .destructive) { deleting = account } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(L10n.t("Remove GitHub display"))
                    }
                }
            }
            Section(L10n.t("About these reports")) {
                Text(L10n.t("Actions reports show the current UTC month's billing usage: runner minutes and net costs after discounts. GitHub may publish billing data with a delay. These are not live workflow metrics or a remaining free-minute quota."))
                Text(L10n.t("The built-in GitHub Copilot display remains available in Accounts. Extra Copilot displays can use different named CLI accounts. Billing access requires a token and role authorized for the selected account, organization or enterprise."))
                Link(L10n.t("GitHub billing API and permissions"), destination: URL(string: "https://docs.github.com/en/billing/tutorials/automate-usage-reporting")!)
            }.font(.callout)
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { account in
            GitHubUsageEditor(preferences: preferences, account: account)
        }
        .alert(L10n.t("Remove this GitHub display?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(L10n.t("Remove"), role: .destructive) {
                guard let account = deleting else { return }
                preferences.removeGitHubUsageAccount(account)
                deleting = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L10n.t("Only this display, its readings and its saved token are removed. GitHub CLI remains signed in."))
        }
    }
}

private struct GitHubUsageEditor: View {
    @ObservedObject var preferences: Preferences
    @State var account: GitHubUsageAccount
    @State private var token = ""
    @State private var feedback: String?
    @State private var testing = false
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { !preferences.githubUsageAccounts.contains { $0.id == account.id } }
    private var missingNewToken: Bool {
        account.authentication == .token && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (isNew || preferences.githubUsageAccounts.first(where: { $0.id == account.id })?.authentication != .token)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("GitHub display")).font(.title2.bold())
            Form {
                TextField(L10n.t("Display name"), text: $account.name)
                Picker(L10n.t("Report"), selection: $account.report) {
                    ForEach(GitHubUsageAccount.Report.allCases) { Text($0.title).tag($0) }
                }
                if account.report != .copilot {
                    TextField(L10n.t("Account / organization / enterprise slug"), text: $account.owner)
                }
                TextField(L10n.t("GitHub host"), text: $account.host)
                Picker(L10n.t("Credentials"), selection: $account.authentication) {
                    ForEach(GitHubUsageAccount.Authentication.allCases) { Text($0.title).tag($0) }
                }
                if account.authentication == .token {
                    SecureField(isNew ? L10n.t("Paste token") : L10n.t("New token (leave empty to keep saved token)"), text: $token)
                    Text(L10n.t("Saved only in your macOS login keychain. Enterprise reports need enterprise billing access; organization reports need organization administration access; personal reports need Plan read access. Authorize SSO if your company requires it."))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField(L10n.t("GitHub CLI username"), text: $account.cliUsername)
                    Text(L10n.t("Uses this already signed-in account explicitly, without switching your terminal's active account. If billing access is denied, use a separate token with billing permissions."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(testing)
            if let feedback { Text(feedback).font(.callout).textSelection(.enabled) }
            if let message = account.validationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button(L10n.t("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button(L10n.t("Test connection")) { testConnection() }
                    .disabled(testing || account.validationMessage != nil || missingNewToken)
                Button(L10n.t("Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(testing || account.validationMessage != nil || missingNewToken)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(testing)
    }

    private func save() {
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && account.authentication == .token {
            guard GitHubUsageCredentials.save(token, account: account) else {
                feedback = L10n.t("Could not save the token in your keychain. No settings were changed.")
                return
            }
        }
        account.credentialRevision = UUID().uuidString
        preferences.saveGitHubUsageAccount(account)
        if account.authentication == .cli { GitHubUsageCredentials.delete(account: account) }
        token = ""
        dismiss()
    }

    private func testConnection() {
        testing = true
        feedback = nil
        let configuration = account
        let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let provider = GitHubUsageProvider(account: configuration, credentialLoader: {
                if configuration.authentication == .token && !enteredToken.isEmpty { return enteredToken }
                return try GitHubUsageCredentials.load(configuration)
            })
            do {
                let snapshot = try await provider.fetchSnapshot()
                feedback = L10n.t("Connected") + " · " + snapshot.windows.map { $0.usedText ?? $0.label }.joined(separator: " · ")
            } catch UsageProviderError.needsAuth {
                feedback = L10n.t("No valid login. Check the token or named CLI account.")
            } catch UsageProviderError.accessDenied {
                feedback = L10n.t("Keychain access was denied. Save a new token in this display.")
            } catch UsageProviderError.apiError(let message) {
                feedback = message
            } catch UsageProviderError.rateLimited {
                feedback = L10n.t("GitHub's rate limit was reached. Wait before trying again.")
            } catch {
                feedback = L10n.t("GitHub could not return this report. Check your connection, credentials and billing access.")
            }
            testing = false
        }
    }
}
