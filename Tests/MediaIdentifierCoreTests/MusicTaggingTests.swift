import XCTest
@testable import MediaIdentifierCore

/// Reading a music file's tags, and deciding where it belongs.
///
/// The samples below were captured from ffprobe 6.1.1 reading files built
/// for the purpose, not written from what the format documentation says.
/// Several of these assertions exist because the measured behaviour is not
/// what one would guess — FLAC in particular.
final class MusicTaggingTests: XCTestCase {

    // MARK: Reading the tags

    /// MP3 and M4A always arrive under canonical lowercase names: the
    /// demuxer maps fixed frame IDs and atoms onto them, so the on-disk
    /// spelling cannot leak through.
    func testAnMP3IsReadFromItsCanonicalLowercaseKeys() {
        let tags = AudioTagParser.parse([
            "title": "Teardrop", "artist": "Massive Attack",
            "album": "Mezzanine", "album_artist": "Massive Attack",
            "date": "1998", "track": "3/11", "disc": "1/1",
        ])
        XCTAssertEqual(tags.title, "Teardrop")
        XCTAssertEqual(tags.album, "Mezzanine")
        XCTAssertEqual(tags.year, 1998)
        XCTAssertEqual(tags.trackNumber, 3)
        XCTAssertEqual(tags.trackTotal, 11)
        XCTAssertTrue(tags.areSufficient)
    }

    /// FLAC does NOT lowercase. Vorbis comments pass through in whatever
    /// case the tagger wrote, so a Picard file yields TITLE and ARTIST —
    /// and a parser keyed on "title" would read nothing at all.
    func testAFlacIsReadDespiteItsKeysBeingUppercase() {
        let tags = AudioTagParser.parse([
            "TITLE": "Teardrop", "ARTIST": "Massive Attack",
            "ALBUM": "Mezzanine", "album_artist": "Massive Attack",
            "DATE": "1998", "track": "3", "TOTALTRACKS": "11",
        ])
        XCTAssertEqual(tags.title, "Teardrop")
        XCTAssertEqual(tags.artist, "Massive Attack")
        XCTAssertEqual(tags.album, "Mezzanine")
        XCTAssertEqual(tags.year, 1998)
        XCTAssertEqual(tags.trackNumber, 3)
        // ffprobe does not fold the separate total into "track".
        XCTAssertEqual(tags.trackTotal, 11)
    }

    /// Only a few Vorbis names are remapped. ALBUM_ARTIST with an
    /// underscore and ALBUM ARTIST with a space both come through
    /// verbatim, so both spellings have to be looked for.
    func testTheUnmappedSpellingsOfAlbumArtistAreFound() {
        for key in ["ALBUM_ARTIST", "ALBUM ARTIST", "albumartist", "AlbumArtist"] {
            let tags = AudioTagParser.parse([
                "TITLE": "x", "ALBUM": "y", key: "Various Artists",
            ])
            XCTAssertEqual(tags.albumArtist, "Various Artists", key)
        }
    }

    /// Several values for one name arrive joined with a semicolon. Kept
    /// whole, the folder would be called "First;Second".
    func testAMultiValueArtistTakesTheFirstName() {
        let tags = AudioTagParser.parse(["ARTIST": "Massive Attack;Elizabeth Fraser"])
        XCTAssertEqual(tags.artist, "Massive Attack")
    }

    func testATrackNumberArrivesInThreeShapes() {
        XCTAssertEqual(AudioTagParser.parse(["track": "3/11"]).trackNumber, 3)
        XCTAssertEqual(AudioTagParser.parse(["track": "3"]).trackNumber, 3)
        XCTAssertEqual(AudioTagParser.parse(["track": "03"]).trackNumber, 3)
        XCTAssertNil(AudioTagParser.parse([:]).trackNumber)
    }

    /// A date field is not always just a year, and a day must not be read
    /// as one.
    func testTheYearIsTakenFromAFullDateWithoutGuessing() {
        XCTAssertEqual(AudioTagParser.parse(["date": "1998"]).year, 1998)
        XCTAssertEqual(AudioTagParser.parse(["date": "1998-04-27"]).year, 1998)
        XCTAssertEqual(AudioTagParser.parse(["date": "27.04.1998"]).year, 1998)
        XCTAssertNil(AudioTagParser.parse(["date": "unknown"]).year)
        XCTAssertNil(AudioTagParser.parse(["date": "12-31"]).year,
                     "a day and a month are not a year")
    }

    /// On a compilation the album belongs to one artist and the tracks to
    /// others; the folder must follow the album's.
    func testACompilationFilesUnderTheAlbumArtist() {
        let tags = AudioTagParser.parse([
            "title": "Teardrop", "artist": "Massive Attack",
            "album_artist": "Various Artists", "album": "Chillout 1998",
        ])
        XCTAssertEqual(tags.effectiveAlbumArtist, "Various Artists")
    }

    func testWithoutAnAlbumArtistTheTrackArtistStands() {
        let tags = AudioTagParser.parse(["artist": "Massive Attack"])
        XCTAssertEqual(tags.effectiveAlbumArtist, "Massive Attack")
    }

    /// What decides whether anything is looked up online at all.
    func testTagsAreSufficientOnlyWithArtistAlbumAndTitle() {
        XCTAssertFalse(AudioTagParser.parse([:]).areSufficient)
        XCTAssertFalse(AudioTagParser.parse(["title": "x", "album": "y"]).areSufficient)
        XCTAssertFalse(AudioTagParser.parse([
            "title": "  ", "album": "y", "artist": "z",
        ]).areSufficient, "whitespace is not a title")
        XCTAssertTrue(AudioTagParser.parse([
            "title": "x", "album": "y", "artist": "z",
        ]).areSufficient)
    }

    // MARK: Where it goes

    private func tags(_ title: String, _ album: String, _ artist: String,
                      year: Int? = nil, track: Int? = nil, trackTotal: Int? = nil,
                      disc: Int? = nil, discTotal: Int? = nil,
                      albumArtist: String? = nil) -> AudioTags {
        AudioTags(title: title, artist: artist, albumArtist: albumArtist, album: album,
                  year: year, trackNumber: track, trackTotal: trackTotal,
                  discNumber: disc, discTotal: discTotal)
    }

    func testATrackGoesUnderArtistAndAlbum() {
        let path = MusicNamer.relativePath(
            for: tags("Teardrop", "Mezzanine", "Massive Attack", year: 1998, track: 3),
            extension: "flac")
        XCTAssertEqual(path, "Massive Attack/Mezzanine (1998)/03 - Teardrop.flac")
    }

    func testWithoutAYearTheAlbumFolderHasNoBrackets() {
        let path = MusicNamer.relativePath(
            for: tags("Teardrop", "Mezzanine", "Massive Attack", track: 3),
            extension: "flac")
        XCTAssertEqual(path, "Massive Attack/Mezzanine/03 - Teardrop.flac")
    }

    func testWithoutATrackNumberTheTitleStandsAlone() {
        let path = MusicNamer.relativePath(
            for: tags("Teardrop", "Mezzanine", "Massive Attack"), extension: "mp3")
        XCTAssertEqual(path, "Massive Attack/Mezzanine/Teardrop.mp3")
    }

    /// Jellyfin calls disc folders optional and says the tags are enough,
    /// so a single-disc album must not get a pointless /Disc 1.
    func testOneDiscGetsNoDiscFolder() {
        let path = MusicNamer.relativePath(
            for: tags("A", "B", "C", track: 1, disc: 1, discTotal: 1), extension: "mp3")
        XCTAssertEqual(path, "C/B/01 - A.mp3")
    }

    func testSeveralDiscsEachGetTheirOwnFolder() {
        let path = MusicNamer.relativePath(
            for: tags("A", "B", "C", track: 1, disc: 2, discTotal: 2), extension: "mp3")
        XCTAssertEqual(path, "C/B/Disc 2/01 - A.mp3")
    }

    /// A hundred tracks need three digits, or they sort wrongly.
    func testALongAlbumPadsToThreeDigits() {
        let path = MusicNamer.relativePath(
            for: tags("A", "B", "C", track: 7, trackTotal: 120), extension: "mp3")
        XCTAssertEqual(path, "C/B/007 - A.mp3")
    }

    /// AC/DC is the standing example: a slash in a name would otherwise
    /// create a folder nobody asked for.
    func testASlashInANameDoesNotBecomeAFolder() {
        let path = MusicNamer.relativePath(
            for: tags("Hells Bells", "Back in Black", "AC/DC", track: 1),
            extension: "flac")
        XCTAssertEqual(path, "AC-DC/Back in Black/01 - Hells Bells.flac")
        XCTAssertEqual(path?.split(separator: "/").count, 3)
    }

    func testAControlCharacterInATagIsRemoved() {
        let path = MusicNamer.relativePath(
            for: tags("Tear\ndrop", "Mezzanine", "Massive Attack", track: 3),
            extension: "flac")
        XCTAssertEqual(path, "Massive Attack/Mezzanine/03 - Teardrop.flac")
    }

    /// Nothing is guessed: a file whose tags do not name all three is left
    /// where it is rather than filed somewhere nobody will look.
    func testIncompleteTagsProposeNothing() {
        XCTAssertNil(MusicNamer.relativePath(
            for: AudioTags(title: "Teardrop"), extension: "flac"))
        XCTAssertNil(MusicNamer.relativePath(for: AudioTags(), extension: "flac"))
    }

    // MARK: The cover

    func testTheCoverGoesBesideTheTracks() {
        XCTAssertEqual(
            MusicNamer.coverPath(forTrackAt: "Massive Attack/Mezzanine (1998)/03 - A.flac"),
            "Massive Attack/Mezzanine (1998)/cover.jpg")
    }

    /// One cover for the album, not one per disc.
    func testAMultiDiscAlbumGetsOneCoverInTheAlbumFolder() {
        XCTAssertEqual(
            MusicNamer.coverPath(forTrackAt: "C/B (2001)/Disc 2/01 - A.mp3"),
            "C/B (2001)/cover.jpg")
    }

    // MARK: Which files are claimed

    func testTheUsualMusicFormatsAreRecognised() {
        for name in ["a.mp3", "a.flac", "a.m4a", "a.opus", "a.ogg", "a.wav", "a.FLAC"] {
            XCTAssertTrue(AudioFileTypes.isAudio(URL(fileURLWithPath: "/x/" + name)), name)
        }
        for name in ["a.mkv", "a.mp4", "a.srt", "a.jpg"] {
            XCTAssertFalse(AudioFileTypes.isAudio(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }

    /// Measured, not assumed: Jellyfin's audio list intersected with this
    /// project's video list is exactly {3gp}. If that ever grows, the two
    /// scanners would start fighting over the same files.
    func testTheOnlyOverlapWithVideoIsTheOneWeKnowAbout() {
        let overlap = AudioFileTypes.audioExtensions
            .intersection(VideoFileTypes.videoExtensions)
        XCTAssertTrue(overlap.isEmpty,
                      "a music extension is also claimed by the video scanner: \(overlap)")
        XCTAssertEqual(AudioFileTypes.claimedByVideoInstead, ["3gp"])
        XCTAssertTrue(VideoFileTypes.videoExtensions.contains("3gp"),
                      "the note says video claims 3gp; it no longer does")
    }

    /// An album that already has art under any of Jellyfin's four accepted
    /// names does not need another file written into it.
    func testAnExistingCoverIsRecognisedUnderAnyAcceptedName() {
        for name in ["cover.jpg", "folder.jpg", "poster.png", "default.jpeg",
                     "Cover.JPG"] {
            XCTAssertTrue(AudioFileTypes.isCoverImage(URL(fileURLWithPath: "/a/" + name)),
                          name)
        }
        for name in ["art.jpg", "cover.txt", "screenshot.png"] {
            XCTAssertFalse(AudioFileTypes.isCoverImage(URL(fileURLWithPath: "/a/" + name)),
                           name)
        }
    }
}
