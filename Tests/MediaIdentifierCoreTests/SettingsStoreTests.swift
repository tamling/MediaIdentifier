import XCTest
@testable import MediaIdentifierCore

/// Tests the settings and secret files: that they round-trip, that damage is
/// survivable, and that credentials are never readable by other accounts or
/// present in the settings file.
final class SettingsStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func permissions(of url: URL) throws -> Int16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).int16Value
    }

    private func sampleSettings() -> WebSettings {
        WebSettings(sourceFolder: "/mnt/downloads",
                    moviesFolder: "/mnt/media/Movies",
                    seriesFolder: "/mnt/media/Series",
                    identification: .localLLM,
                    localLLMBaseURL: "http://192.168.3.116:1234",
                    localLLMModel: "qwen/qwen3.6-35b-a3b",
                    jellyfinBaseURL: "http://192.168.3.116:8096",
                    conflictPolicy: .rename,
                    watchSourceFolder: true)
    }

    // MARK: Settings

    func testFirstStartUsesDefaultsAndSaysSoWithoutFailing() {
        let store = SettingsStore(directory: directory)
        let result = store.load()
        XCTAssertEqual(result.state, .missing)
        XCTAssertEqual(result.settings, WebSettings())
    }

    func testSettingsRoundTrip() throws {
        let store = SettingsStore(directory: directory)
        try store.save(sampleSettings())
        let result = store.load()
        XCTAssertEqual(result.state, .loaded)
        XCTAssertEqual(result.settings, sampleSettings())
    }

    func testSavingNormalisesWhatItWrites() throws {
        let store = SettingsStore(directory: directory)
        var messy = sampleSettings()
        messy.sourceFolder = "  /mnt/downloads/  "
        messy.localLLMBaseURL = "http://192.168.3.116:1234/"
        try store.save(messy)
        XCTAssertEqual(store.load().settings.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(store.load().settings.localLLMBaseURL, "http://192.168.3.116:1234")
    }

    /// A damaged file must not stop the app, or the user cannot reach the
    /// interface that would let them fix it.
    func testADamagedSettingsFileFallsBackToDefaultsAndIsLeftAlone() throws {
        let store = SettingsStore(directory: directory)
        try Data("{ this is not json".utf8).write(to: store.fileURL)

        let result = store.load()
        XCTAssertEqual(result.settings, WebSettings())
        guard case .unreadable = result.state else {
            return XCTFail("expected the damage to be reported, got \(result.state)")
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL),
                       Data("{ this is not json".utf8),
                       "the damaged file must still be there to look at")
    }

    func testSettingsFileIsNotReadableByOtherAccounts() throws {
        let store = SettingsStore(directory: directory)
        try store.save(sampleSettings())
        XCTAssertEqual(try permissions(of: store.fileURL) & 0o077, 0)
    }

    /// A write replaces the file only once the new contents are complete.
    func testNoTemporaryFileIsLeftBehind() throws {
        let store = SettingsStore(directory: directory)
        try store.save(sampleSettings())
        try store.save(sampleSettings())
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents.filter { $0.hasSuffix(".tmp") }, [])
    }

    // MARK: Secrets

    func testSecretRoundTripAndRemoval() throws {
        let store = SecretStore(directory: directory)
        XCTAssertNil(store.value(for: .localLLMAPIKey))
        XCTAssertTrue(store.configuredKeys().isEmpty)

        try store.set("sk-local-123", for: .localLLMAPIKey)
        XCTAssertEqual(store.value(for: .localLLMAPIKey), "sk-local-123")
        XCTAssertEqual(store.configuredKeys(), [.localLLMAPIKey])

        try store.set("", for: .localLLMAPIKey)
        XCTAssertNil(store.value(for: .localLLMAPIKey))
        XCTAssertTrue(store.configuredKeys().isEmpty)
    }

    func testSecretsAreIndependentOfEachOther() throws {
        let store = SecretStore(directory: directory)
        try store.set("llm", for: .localLLMAPIKey)
        try store.set("jelly", for: .jellyfinToken)
        try store.set("", for: .localLLMAPIKey)
        XCTAssertEqual(store.value(for: .jellyfinToken), "jelly",
                       "removing one key must not disturb another")
        XCTAssertEqual(store.configuredKeys(), [.jellyfinToken])
    }

    func testWhitespaceOnlySecretCountsAsUnset() throws {
        let store = SecretStore(directory: directory)
        try store.set("   \n", for: .tmdbAPIKey)
        XCTAssertNil(store.value(for: .tmdbAPIKey))
        XCTAssertTrue(store.configuredKeys().isEmpty)
    }

    func testStoredSecretIsNotReadableByOtherAccounts() throws {
        let store = SecretStore(directory: directory)
        try store.set("sk-local-123", for: .localLLMAPIKey)
        XCTAssertEqual(try permissions(of: store.fileURL) & 0o077, 0)
        XCTAssertFalse(store.isReadableByOthers)
    }

    func testLoosePermissionsAreTightenedAndReported() throws {
        let store = SecretStore(directory: directory)
        try store.set("sk-local-123", for: .localLLMAPIKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: store.fileURL.path)
        XCTAssertTrue(store.isReadableByOthers)
        XCTAssertTrue(store.tightenPermissionsIfNeeded())
        XCTAssertFalse(store.isReadableByOthers)
        XCTAssertFalse(store.tightenPermissionsIfNeeded(), "nothing to do the second time")
        XCTAssertEqual(store.value(for: .localLLMAPIKey), "sk-local-123")
    }

    /// The point of two files: the settings can be read without exposing keys.
    func testNoSecretEverAppearsInTheSettingsFile() throws {
        let settingsStore = SettingsStore(directory: directory)
        let secretStore = SecretStore(directory: directory)
        try settingsStore.save(sampleSettings())
        try secretStore.set("sk-local-123", for: .localLLMAPIKey)
        try secretStore.set("jellyfin-api-key", for: .jellyfinToken)

        let settingsText = String(decoding: try Data(contentsOf: settingsStore.fileURL),
                                  as: UTF8.self)
        XCTAssertFalse(settingsText.contains("sk-local-123"))
        XCTAssertFalse(settingsText.contains("jellyfin-api-key"))
        XCTAssertNotEqual(settingsStore.fileURL, secretStore.fileURL)
    }

    func testADamagedSecretsFileReadsAsEmptyRatherThanThrowing() throws {
        let store = SecretStore(directory: directory)
        try Data("not json at all".utf8).write(to: store.fileURL)
        XCTAssertNil(store.value(for: .localLLMAPIKey))
        XCTAssertTrue(store.configuredKeys().isEmpty)
        // And a write still succeeds, replacing the damage.
        try store.set("recovered", for: .localLLMAPIKey)
        XCTAssertEqual(store.value(for: .localLLMAPIKey), "recovered")
    }

    // MARK: Directory handling

    func testTheDirectoryIsCreatedIfMissing() throws {
        let nested = directory.appendingPathComponent("deeper/still")
        let store = SettingsStore(directory: nested)
        try store.save(sampleSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.load().settings, sampleSettings())
    }
}
