import XCTest
@testable import Codenotch

final class AtriumClaudeProfileTests: XCTestCase {
    func testDiscoveryAddsSecondAccountAndDeduplicatesNativeLogin() throws {
        let home = try fixture()
        let profiles = ClaudeProfile.discover(home: home, hasCredential: { _ in true })
        XCTAssertEqual(profiles.map(\.id), ["claude", "claude-atrium-work"])
        XCTAssertEqual(profiles.last?.displayName, "Claude Acme")
        XCTAssertEqual(profiles.last?.signedInAddress(), "other@acme.com")
        XCTAssertEqual(profiles.last?.sourceName, "Atrium")
        XCTAssertNil(profiles.last?.organizationID())
        XCTAssertEqual(ClaudeOAuthProvider(profile: profiles.last!).signInRoute,
                       .guidance("Reconnect this Claude account in Atrium, then refresh Codenotch."))
    }

    func testMissingCredentialDoesNotCreatePhantomAccount() throws {
        let home = try fixture()
        XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: { _ in false }).count, 1)
    }

    func testUntrustedOrInactiveRecordsAreIgnored() throws {
        for change in ["state", "path", "keychainService", "version"] {
            let home = try fixture()
            let url = home.appendingPathComponent(".atrium/claude-accounts-stores.json")
            var registry = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            if change == "version" {
                registry["version"] = 99
            } else {
                var records = registry["records"] as! [String: [String: Any]]
                records["work"]![change] = change == "path" ? "/tmp/unrelated" : "invalid"
                registry["records"] = records
            }
            try JSONSerialization.data(withJSONObject: registry).write(to: url)
            XCTAssertEqual(ClaudeProfile.discover(home: home, hasCredential: { _ in true }).count, 1, change)
        }
    }

    private func fixture() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".atrium"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        var records: [String: Any] = [:]
        for (key, email) in [("personal", "ME@example.com"), ("work", "other@acme.com")] {
            let directory = home.appendingPathComponent(".atrium/claude-accounts/\(key)/securestore")
            let profile = ClaudeProfile(slug: key, configDirectory: directory)
            records[key] = ["path": directory.path, "email": email, "state": "active",
                            "keychainService": profile.keychainService]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "records": records])
            .write(to: home.appendingPathComponent(".atrium/claude-accounts-stores.json"))
        return home
    }
}
