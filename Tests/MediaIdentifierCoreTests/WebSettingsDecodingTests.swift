import XCTest
@testable import MediaIdentifierCore

/// The settings decoder is deliberately tolerant: a settings file written by an
/// older version, or damaged by hand, must still load with defaults for the
/// parts it cannot read, rather than throwing and leaving the user with no
/// settings at all. These tests pin that behaviour down, because the decoder is
/// hand-written and its two failure paths look identical from the outside.
final class WebSettingsDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> WebSettings {
        try JSONDecoder().decode(WebSettings.self, from: Data(json.utf8))
    }

    func testEmptyObjectYieldsAllDefaults() throws {
        XCTAssertEqual(try decode("{}"), WebSettings())
    }

    /// A file from an older version: it simply has no key for a field added
    /// later. Everything it does carry must survive.
    func testAbsentKeysFallBackWithoutLosingThePresentOnes() throws {
        let settings = try decode(#"{"sourceFolder":"/import","watchSourceFolder":true}"#)
        XCTAssertEqual(settings.sourceFolder, "/import")
        XCTAssertEqual(settings.watchSourceFolder, true)
        XCTAssertEqual(settings.moviesFolder, WebSettings().moviesFolder)
        XCTAssertEqual(settings.conversion, WebSettings().conversion)
    }

    /// The other failure path, which used to be reached through a different
    /// branch: the key is there but holds the wrong type. It must not throw,
    /// and it must not take the neighbouring fields down with it.
    func testWrongTypeFallsBackAndTheRestStillLoads() throws {
        let settings = try decode(#"{"sourceFolder":42,"moviesFolder":"/movies"}"#)
        XCTAssertEqual(settings.sourceFolder, WebSettings().sourceFolder)
        XCTAssertEqual(settings.moviesFolder, "/movies")
    }

    func testUnknownEnumValueFallsBackRatherThanThrowing() throws {
        let settings = try decode(#"{"conflictPolicy":"obliterate","seriesFolder":"/series"}"#)
        XCTAssertEqual(settings.conflictPolicy, WebSettings().conflictPolicy)
        XCTAssertEqual(settings.seriesFolder, "/series")
    }

    /// An explicit null is not the same as an absent key to `decodeIfPresent`,
    /// so it gets its own case: for a non-optional field the default has to
    /// stand.
    func testExplicitNullFallsBack() throws {
        let settings = try decode(#"{"moviesFolder":null,"seriesFolder":"/series"}"#)
        XCTAssertEqual(settings.moviesFolder, WebSettings().moviesFolder)
        XCTAssertEqual(settings.seriesFolder, "/series")
    }

    /// A nested object that is itself damaged must not discard the whole file.
    func testDamagedNestedObjectFallsBackOnItsOwn() throws {
        let settings = try decode(#"{"conversion":"not-an-object","sourceFolder":"/import"}"#)
        XCTAssertEqual(settings.conversion, WebSettings().conversion)
        XCTAssertEqual(settings.sourceFolder, "/import")
    }

    func testUnknownKeysAreIgnored() throws {
        let settings = try decode(#"{"sourceFolder":"/import","somethingFromTheFuture":{"a":1}}"#)
        XCTAssertEqual(settings.sourceFolder, "/import")
    }

    /// Whatever the decoder tolerates, a round trip of real settings must be
    /// exact — tolerance is for broken input, not for silently dropping data.
    func testRoundTripIsLossless() throws {
        var original = WebSettings()
        original.sourceFolder = "/srv/import"
        original.moviesFolder = "/srv/movies"
        original.seriesFolder = "/srv/series"
        original.localLLMBaseURL = "http://192.168.3.116:1234"
        original.localLLMModel = "some-model"
        original.jellyfinBaseURL = "http://192.168.3.10:8096"
        original.conflictPolicy = .rename
        original.watchSourceFolder = true

        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WebSettings.self, from: data), original)
    }

    /// Top-level garbage is a different matter: there is nothing to be tolerant
    /// about, and the caller needs to hear that so it can leave the file alone
    /// instead of overwriting it with defaults.
    func testTopLevelGarbageStillThrows() {
        XCTAssertThrowsError(try decode("this is not json"))
        XCTAssertThrowsError(try decode("[]"))
    }
    // MARK: The raw values a settings file has to use

    /// A settings file is hand-written in CI and by anybody configuring the
    /// headless service, and the decoder is deliberately lenient: an unknown
    /// value falls back to the default rather than throwing. That leniency
    /// is right for a file somebody edited, and it means a MISSPELLED value
    /// is silent.
    ///
    /// CI wrote `"identification":"localLLM"` in the step that exists to
    /// drive a hostile model server. The raw value is `local-llm`, so
    /// identification stayed at `offline`, no provider was ever built, and
    /// that step never contacted the server — green on every run, for as
    /// long as it had existed. These are the spellings; if one changes here,
    /// every hand-written settings.json has to change with it.
    func testTheRawValuesAreWhatAFileHasToWrite() {
        XCTAssertEqual(IdentificationMode.offline.rawValue, "offline")
        XCTAssertEqual(IdentificationMode.localLLM.rawValue, "local-llm")
        XCTAssertEqual(IdentificationMode.tmdb.rawValue, "tmdb")
        XCTAssertEqual(LibraryMode.video.rawValue, "video")
        XCTAssertEqual(LibraryMode.music.rawValue, "music")
        XCTAssertEqual(Language.german.rawValue, "de")
        XCTAssertEqual(Language.english.rawValue, "en")
    }

    /// And the leniency itself, stated from the other side: a misspelling
    /// does not throw, which is why it has to be pinned above rather than
    /// discovered.
    func testAMisspelledIdentificationModeFallsBackSilently() throws {
        let data = Data("""
            {"sourceFolder":"/srv/dl","identification":"localLLM"}
            """.utf8)
        let decoded = try JSONDecoder().decode(WebSettings.self, from: data)
        XCTAssertEqual(decoded.identification, .offline,
                       "the fallback changed — CI's hand-written settings "
                           + "files depend on knowing what it is")
        XCTAssertEqual(decoded.sourceFolder, "/srv/dl",
                       "one bad value must not take the rest of the file")
    }

}
