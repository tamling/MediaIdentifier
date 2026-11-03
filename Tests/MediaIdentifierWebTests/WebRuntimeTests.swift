import XCTest
import MediaIdentifierCore
@testable import MediaIdentifierWeb

/// Tests for the `mediafin` binary's configuration: where things are stored,
/// how the token file is protected, and how the command line is read.
final class WebRuntimeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-runtime-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: Configuration directory

    func testExplicitConfigDirectoryWins() {
        let directory = MediafinPaths.configDirectory(environment: [
            "MEDIAFIN_CONFIG_DIR": "/srv/mediafin",
            "HOME": "/home/someone",
            "XDG_CONFIG_HOME": "/home/someone/.conf",
        ])
        XCTAssertEqual(directory.path, "/srv/mediafin")
    }

    func testEmptyEnvironmentValuesAreIgnored() {
        let directory = MediafinPaths.configDirectory(environment: [
            "MEDIAFIN_CONFIG_DIR": "",
            "HOME": "/home/someone",
            "XDG_CONFIG_HOME": "",
        ])
        XCTAssertNotEqual(directory.path, "")
        XCTAssertTrue(directory.path.hasPrefix("/home/someone"), directory.path)
    }

    func testPlatformConvention() {
        let directory = MediafinPaths.configDirectory(environment: ["HOME": "/home/someone"])
        #if os(macOS)
        XCTAssertEqual(directory.path, "/home/someone/Library/Application Support/Mediafin")
        #else
        XCTAssertEqual(directory.path, "/home/someone/.config/mediafin")
        #endif
    }

    #if !os(macOS)
    func testXDGConfigHomeIsHonouredOnLinux() {
        let directory = MediafinPaths.configDirectory(environment: [
            "HOME": "/home/someone",
            "XDG_CONFIG_HOME": "/elsewhere/config",
        ])
        XCTAssertEqual(directory.path, "/elsewhere/config/mediafin")
    }
    #endif

    // MARK: Token storage

    func testCreatesATokenOnFirstUse() throws {
        let store = TokenStore(directory: scratch)
        let first = try store.loadOrCreate()
        XCTAssertEqual(first.outcome, .created)
        XCTAssertEqual(first.token.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testTokenSurvivesARestart() throws {
        let store = TokenStore(directory: scratch)
        let created = try store.loadOrCreate().token
        let reloaded = try TokenStore(directory: scratch).loadOrCreate()
        XCTAssertEqual(reloaded.token, created, "a restart must not sign everyone out")
        XCTAssertEqual(reloaded.outcome, .loaded)
    }

    func testStoredTokenIsNotReadableByOtherAccounts() throws {
        let store = TokenStore(directory: scratch)
        _ = try store.loadOrCreate()
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o077, 0)
        XCTAssertFalse(store.isReadableByOthers)
    }

    /// A token file left world-readable is tightened, and the caller is told
    /// so it can suggest rotating.
    func testLooseTokenPermissionsAreTightenedAndReported() throws {
        let store = TokenStore(directory: scratch)
        _ = try store.loadOrCreate()
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: store.fileURL.path)
        XCTAssertTrue(store.isReadableByOthers)

        let reloaded = try store.loadOrCreate()
        XCTAssertEqual(reloaded.outcome, .loadedAndTightened)
        XCTAssertFalse(store.isReadableByOthers)
    }

    /// A token the user chose themselves must be kept, not replaced.
    func testAHandWrittenTokenIsKept() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = TokenStore(directory: scratch)
        try Data("my-own-passphrase\n".utf8).write(to: store.fileURL)
        XCTAssertEqual(try store.loadOrCreate().token, "my-own-passphrase")
    }

    func testAnEmptyTokenFileIsReplaced() throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let store = TokenStore(directory: scratch)
        try Data("   \n".utf8).write(to: store.fileURL)
        let result = try store.loadOrCreate()
        XCTAssertEqual(result.outcome, .created)
        XCTAssertEqual(result.token.count, 64)
    }

    func testRotatingReplacesTheToken() throws {
        let store = TokenStore(directory: scratch)
        let original = try store.loadOrCreate().token
        let rotated = try store.rotate()
        XCTAssertNotEqual(rotated, original)
        XCTAssertEqual(try store.loadOrCreate().token, rotated)
        XCTAssertFalse(store.isReadableByOthers)
    }

    // MARK: Command line

    func testDefaultsAreTheSafeOnes() throws {
        let options = try MediafinOptions.parse([])
        XCTAssertTrue(options.bindLocalOnly, "the interface must not be exposed by default")
        XCTAssertTrue(options.tlsEnabled, "encryption must be on by default")
        XCTAssertFalse(options.allowPlainHTTPOnNetwork)
        XCTAssertEqual(options.port, 8720)
    }

    func testParsesEveryOption() throws {
        let options = try MediafinOptions.parse([
            "--port", "9443", "--bind", "all",
            "--cert", "/etc/ssl/cert.pem", "--key", "/etc/ssl/key.pem",
            "--config-dir", "/srv/mediafin",
        ])
        XCTAssertEqual(options.port, 9443)
        XCTAssertFalse(options.bindLocalOnly)
        XCTAssertEqual(options.certificatePath, "/etc/ssl/cert.pem")
        XCTAssertEqual(options.privateKeyPath, "/etc/ssl/key.pem")
        XCTAssertEqual(options.configDirectory, "/srv/mediafin")
    }

    func testShortFormsAndBindSynonyms() throws {
        XCTAssertEqual(try MediafinOptions.parse(["-p", "80"]).port, 80)
        XCTAssertTrue(try MediafinOptions.parse(["-h"]).showHelp)
        XCTAssertTrue(try MediafinOptions.parse(["--bind", "loopback"]).bindLocalOnly)
        XCTAssertFalse(try MediafinOptions.parse(["--bind", "ANY"]).bindLocalOnly)
    }

    func testRejectsBadInput() {
        let cases: [([String], MediafinOptions.Failure)] = [
            (["--port", "70000"], .invalidPort("70000")),
            (["--port", "eight"], .invalidPort("eight")),
            (["--port"], .missingValue("--port")),
            (["--bind", "sideways"], .invalidBind("sideways")),
            (["--nope"], .unknownOption("--nope")),
            (["--cert", "/a.pem"], .certificateAndKeyGoTogether),
            (["--key", "/a.key"], .certificateAndKeyGoTogether),
        ]
        for (arguments, expected) in cases {
            XCTAssertThrowsError(try MediafinOptions.parse(arguments),
                                 "expected \(arguments) to be rejected") { error in
                XCTAssertEqual(error as? MediafinOptions.Failure, expected)
            }
        }
    }

    // MARK: TLS source selection

    func testSuppliedCertificateIsUsedWithoutGeneratingOne() throws {
        var options = MediafinOptions()
        options.certificatePath = "/etc/ssl/cert.pem"
        options.privateKeyPath = "/etc/ssl/key.pem"
        let source = try options.tlsSource(generated: try mustNotGenerate())
        XCTAssertEqual(source, .pemFiles(certificateChain: "/etc/ssl/cert.pem",
                                         privateKey: "/etc/ssl/key.pem"))
    }

    func testGeneratedCertificateIsUsedWhenNoneSupplied() throws {
        let generated = WebTLSSource.pemFiles(certificateChain: "/tmp/c.pem",
                                              privateKey: "/tmp/k.pem")
        XCTAssertEqual(try MediafinOptions().tlsSource(generated: generated), generated)
    }

    func testNoTLSMeansNoSourceAndNoGeneration() throws {
        var options = MediafinOptions()
        options.tlsEnabled = false
        let source = try options.tlsSource(generated: try mustNotGenerate())
        XCTAssertNil(source, "--no-tls must not create a certificate")
    }

    func testHelpTextMentionsTheRiskyFlag() {
        XCTAssertTrue(MediafinOptions.helpText.contains("--no-tls"))
        XCTAssertTrue(MediafinOptions.helpText.contains("--rotate-token"))
        XCTAssertTrue(MediafinOptions.helpText.contains("self-signed"))
    }

    /// Stands in for certificate generation in the cases where it must not
    /// happen at all.
    private func mustNotGenerate() throws -> WebTLSSource {
        XCTFail("no certificate should have been generated")
        throw Unexpected.generated
    }

    private enum Unexpected: Error { case generated }
}
