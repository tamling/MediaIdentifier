import XCTest
@testable import MediaIdentifierCore

/// Which language the interface speaks, and how it decides.
///
/// The decision is worth testing rather than trying: it is made once at
/// startup, and if it is wrong the user sees a whole window in a language
/// they did not ask for, with nothing on screen explaining why.
final class TextTests: XCTestCase {

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    // MARK: Reading the environment

    func testTheUsualLocaleSpellingsAreUnderstood() {
        for value in ["de", "de_DE", "de_DE.UTF-8", "de_AT.UTF-8", "DE_de"] {
            XCTAssertEqual(Language.fromEnvironment(["LANG": value]), .german, value)
        }
        for value in ["en", "en_GB", "en_US.UTF-8", "en_IE@euro"] {
            XCTAssertEqual(Language.fromEnvironment(["LANG": value]), .english, value)
        }
    }

    /// "C" is not a request for English, it is a request for no localisation
    /// at all — but English is the closest this program has to that, and it
    /// is what every other tool does.
    func testTheCLocaleMeansEnglish() {
        XCTAssertEqual(Language.fromEnvironment(["LANG": "C"]), .english)
        XCTAssertEqual(Language.fromEnvironment(["LANG": "POSIX"]), .english)
        XCTAssertEqual(Language.fromEnvironment(["LC_ALL": "C.UTF-8"]), .english)
    }

    /// The order the C library itself uses. A machine with LANG=de and
    /// LC_ALL=en is asking for English, and getting that backwards would
    /// override the more specific setting with the less.
    func testLCAllWinsOverLangAndEmptyValuesAreNotAnAnswer() {
        XCTAssertEqual(Language.fromEnvironment(["LC_ALL": "en_US", "LANG": "de_DE"]),
                       .english)
        XCTAssertEqual(Language.fromEnvironment(["LC_MESSAGES": "en_US", "LANG": "de_DE"]),
                       .english)
        // An empty variable is not a setting; the next one down is consulted.
        XCTAssertEqual(Language.fromEnvironment(["LC_ALL": "", "LANG": "de_DE"]), .german)
    }

    /// A language it cannot speak must not silently become one it can: nil
    /// lets the caller's own default decide, which is the difference between
    /// "no preference" and "preferred Finnish".
    func testAnUnknownLanguageIsNotGuessed() {
        XCTAssertNil(Language.fromEnvironment(["LANG": "fi_FI.UTF-8"]))
        XCTAssertNil(Language.fromEnvironment([:]))
    }

    // MARK: Choosing at startup

    func testTheSettingBeatsTheEnvironment() {
        // A media server is quite often run under a different locale than
        // its owner reads.
        Text.start(configured: .english, environment: ["LANG": "de_DE.UTF-8"])
        XCTAssertEqual(Text.language, .english)
        Text.start(configured: .german, environment: ["LANG": "en_US.UTF-8"])
        XCTAssertEqual(Text.language, .german)
    }

    func testWithNoSettingTheEnvironmentDecides() {
        Text.start(configured: nil, environment: ["LANG": "en_GB.UTF-8"])
        XCTAssertEqual(Text.language, .english)
    }

    func testWithNeitherItStaysGerman() {
        Text.start(configured: nil, environment: [:])
        XCTAssertEqual(Text.language, .german)
    }

    // MARK: Saying it

    func testAPhraseFollowsTheLanguage() {
        Text.language = .german
        XCTAssertEqual(Text.s("Durchsuchen", "Scan"), "Durchsuchen")
        Text.language = .english
        XCTAssertEqual(Text.s("Durchsuchen", "Scan"), "Scan")
    }

    /// Each language names itself in itself: somebody who has landed in the
    /// wrong one cannot read the other one's name for it.
    func testEachLanguageNamesItselfInItsOwnWords() {
        XCTAssertEqual(Language.german.label, "Deutsch")
        XCTAssertEqual(Language.english.label, "English")
    }
}
