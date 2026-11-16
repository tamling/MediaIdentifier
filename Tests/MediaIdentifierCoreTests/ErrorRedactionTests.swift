import XCTest
@testable import MediaIdentifierCore

/// A credential must not travel out in an error message.
///
/// TMDb's v3 API is designed to carry its key as a query parameter, and
/// `URLError` keeps the failing URL in its userInfo. `describe` uses
/// `errorDescription` first, which today does not include the URL — but
/// that is a property of URLError's LocalizedError conformance, not
/// something this code asked for, and the fallback branch prints userInfo
/// and everything in it. These messages go into `rename-log.json`, which
/// the README invites people to paste into a bug report.
final class ErrorRedactionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Text.language = .german
    }

    func testAKeyInAQueryStringIsRemoved() {
        let text = AppCoordinator.redacting(
            "https://api.themoviedb.org/3/search/movie?api_key=0123456789abcdef"
                + "0123456789abcdef&query=Tenet")
        XCTAssertFalse(text.contains("0123456789abcdef"), text)
        XCTAssertTrue(text.contains("query=Tenet"),
                      "it took the rest of the URL with it: \(text)")
    }

    func testEveryCredentialParameterNameIsCovered() {
        for name in ["api_key", "API_KEY", "access_token", "token", "key", "password"] {
            let text = AppCoordinator.redacting("http://h/x?\(name)=s3cr3tvalue&a=b")
            XCTAssertFalse(text.contains("s3cr3tvalue"), "\(name): \(text)")
            XCTAssertTrue(text.contains("a=b"), "\(name): \(text)")
        }
    }

    func testABearerTokenIsRemoved() {
        let text = AppCoordinator.redacting(
            "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-_123 failed")
        XCTAssertFalse(text.contains("eyJhbGciOiJIUzI1NiJ9"), text)
        XCTAssertTrue(text.contains("failed"), text)
    }

    /// It must not eat ordinary words. A redactor that mangles every message
    /// gets switched off by whoever notices.
    func testOrdinaryTextIsUntouched() {
        for text in ["Die Verbindung wurde abgelehnt.",
                     "The monkey=brand file could not be read",
                     "/home/user/Videos/Tenet (2020)/Tenet (2020).mkv",
                     "ffmpeg exited with status 1",
                     "No such file or directory"] {
            XCTAssertEqual(AppCoordinator.redacting(text), text)
        }
    }

    /// Through the function the program actually calls, not only the helper.
    func testDescribeRedactsToo() {
        struct Failing: LocalizedError {
            var errorDescription: String? {
                "GET https://api.themoviedb.org/3/x?api_key=deadbeefdeadbeef failed"
            }
        }
        let text = AppCoordinator.describe(Failing())
        XCTAssertFalse(text.contains("deadbeefdeadbeef"), text)
    }

    /// A real URLError, whose userInfo is what the fallback branch prints.
    func testAURLErrorCannotLeakItsFailingURL() {
        let url = URL(string: "https://api.themoviedb.org/3/x?api_key=deadbeefdeadbeef")!
        let error = NSError(domain: NSURLErrorDomain,
                            code: NSURLErrorCannotConnectToHost,
                            userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString,
                                       NSURLErrorFailingURLErrorKey: url])
        XCTAssertFalse(AppCoordinator.describe(error).contains("deadbeefdeadbeef"),
                       AppCoordinator.describe(error))
    }
}
