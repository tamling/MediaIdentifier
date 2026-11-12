import XCTest
@testable import MediaIdentifierCore

/// The palette, which the window's stylesheet is built from.
///
/// It was shared with a web interface that no longer exists, and two tests
/// here went with it: they rendered the status page and insisted every colour
/// in it came from the palette, which is the guard that would have caught a
/// hard-coded shade growing beside the shared ones.
///
/// That guard is now missing, and saying so is better than quietly having less
/// cover than it looks: the window's stylesheet lives in the mediafin-gtk
/// target, which a Core test cannot import. What is left below checks the
/// palette itself — that each colour is real, that none is a duplicate, and
/// that the pairings the interface is actually made of can be read.
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
