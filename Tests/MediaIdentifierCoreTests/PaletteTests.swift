import XCTest
@testable import MediaIdentifierCore

/// The palette is shared so the native window and the web interface look like
/// one product. These tests exist to keep that true: the colours used to be
/// written into the status page by hand, and nothing would have noticed if a
/// second set had grown beside them.
final class PaletteTests: XCTestCase {

    private var all: [(name: String, value: String)] {
        [("background", Palette.background), ("surface", Palette.surface),
         ("surfaceRaised", Palette.surfaceRaised), ("border", Palette.border),
         ("text", Palette.text), ("textMuted", Palette.textMuted),
         ("ok", Palette.ok), ("busy", Palette.busy), ("error", Palette.error),
         ("onAccent", Palette.onAccent)]
    }

    func testEveryColourIsAValidSixDigitHex() {
        for entry in all {
            XCTAssertEqual(entry.value.count, 7, "\(entry.name) is \(entry.value)")
            XCTAssertTrue(entry.value.hasPrefix("#"), "\(entry.name) is \(entry.value)")
            XCTAssertTrue(
                entry.value.dropFirst().allSatisfy { $0.isHexDigit },
                "\(entry.name) is not hex: \(entry.value)"
            )
        }
    }

    func testColoursAreDistinct() {
        let values = all.map(\.value)
        XCTAssertEqual(Set(values).count, values.count,
                       "two names point at the same colour: \(values)")
    }

    /// The status page must render the palette, not its own copy of it.
    func testTheStatusPageUsesThePalette() {
        let html = StatusHTTP.html(StatusSnapshot())
        XCTAssertTrue(html.contains(Palette.background))
        XCTAssertTrue(html.contains(Palette.surface))
        XCTAssertTrue(html.contains(Palette.text))
        XCTAssertTrue(html.contains(Palette.textMuted))
    }

    /// The guard that matters: no colour literal may reappear in the page
    /// outside the palette. This is what would catch a new hard-coded shade
    /// being added next to the shared ones.
    func testTheStatusPageContainsNoColourOutsideThePalette() {
        let html = StatusHTTP.html(StatusSnapshot())
        let known = Set(all.map { $0.value.lowercased() })
        var found: Set<String> = []
        var index = html.startIndex
        while let hash = html[index...].firstIndex(of: "#") {
            let after = html.index(after: hash)
            let candidate = String(html[after...].prefix(6))
            if candidate.count == 6, candidate.allSatisfy({ $0.isHexDigit }) {
                found.insert("#" + candidate.lowercased())
            }
            index = after
            if index >= html.endIndex { break }
        }
        XCTAssertTrue(found.isSubset(of: known),
                      "colours outside the palette: \(found.subtracting(known).sorted())")
    }

    /// The accent is used as a background with `onAccent` on top, so the two
    /// have to be far enough apart to read.
    func testAccentAndItsForegroundAreFarApart() {
        func luminance(_ hex: String) -> Double {
            let digits = Array(hex.dropFirst())
            func channel(_ offset: Int) -> Double {
                Double(UInt8(String(digits[offset...(offset + 1)]), radix: 16) ?? 0) / 255
            }
            return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4)
        }
        let light = luminance(Palette.ok) + 0.05
        let dark = luminance(Palette.onAccent) + 0.05
        XCTAssertGreaterThan(light / dark, 4.5,
                             "accent text would be hard to read on the accent colour")
    }

    /// Body text on the window background, the pairing most of the interface
    /// is made of.
    func testTextOnBackgroundIsReadable() {
        func luminance(_ hex: String) -> Double {
            let digits = Array(hex.dropFirst())
            func channel(_ offset: Int) -> Double {
                Double(UInt8(String(digits[offset...(offset + 1)]), radix: 16) ?? 0) / 255
            }
            return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4)
        }
        let ratio = (luminance(Palette.text) + 0.05) / (luminance(Palette.background) + 0.05)
        XCTAssertGreaterThan(ratio, 7, "body text does not reach AAA on the background")
    }
}

/// The version is defined in one place and read by the packaging script, so
/// a change of shape there breaks the .deb rather than the compiler.
final class MediafinVersionTests: XCTestCase {

    func testIsThreeDottedNumbers() {
        let parts = MediafinVersion.number.split(separator: ".")
        XCTAssertEqual(parts.count, 3, MediafinVersion.number)
        for part in parts {
            XCTAssertFalse(part.isEmpty)
            XCTAssertTrue(part.allSatisfy(\.isNumber), "\(part) in \(MediafinVersion.number)")
        }
    }

    /// Debian composes its own version as "<number>~git<date>.<sha>", so the
    /// number must not already carry build metadata.
    func testCarriesNoBuildMetadata() {
        for marker in ["~", "-", "+", "git", " "] {
            XCTAssertFalse(MediafinVersion.number.contains(marker),
                           "the package script cannot compose a version containing \(marker)")
        }
    }

    func testDisplayNamesTheProduct() {
        XCTAssertTrue(MediafinVersion.display.hasPrefix("Mediafin "))
        XCTAssertTrue(MediafinVersion.display.hasSuffix(MediafinVersion.number))
    }
}
