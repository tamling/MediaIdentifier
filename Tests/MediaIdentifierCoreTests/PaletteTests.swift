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
         ("accent", Palette.accent), ("onAccent", Palette.onAccent)]
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

    /// WCAG's relative luminance, gamma and all.
    ///
    /// The version here before left the sRGB gamma step out, which is not a
    /// rounding difference: on a saturated colour it can rank two
    /// foregrounds the wrong way round. On the accent red it claims black
    /// beats white, 5.23 against 4.02, where the real formula says the
    /// opposite, 4.30 against 4.88 -- so a foreground chosen by that measure
    /// would have been the harder one to read, with a passing test on top.
    private func luminance(_ hex: String) -> Double {
        let digits = Array(hex.dropFirst())
        func channel(_ offset: Int) -> Double {
            let raw = Double(UInt8(String(digits[offset...(offset + 1)]),
                                   radix: 16) ?? 0) / 255
            return raw <= 0.04045 ? raw / 12.92
                                  : pow((raw + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4)
    }

    private func contrast(_ one: String, _ other: String) -> Double {
        let a = luminance(one), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The published numbers, so a change of formula cannot pass unnoticed.
    func testTheLuminanceIsWCAGs() {
        XCTAssertEqual(contrast("#ffffff", "#000000"), 21, accuracy: 0.01,
                       "white on black is 21:1 by definition")
        XCTAssertEqual(contrast("#777777", "#ffffff"), 4.48, accuracy: 0.01,
                       "mid grey on white is the textbook 4.48:1; the "
                           + "gamma-free version gets 2.03 here. White on "
                           + "black is 21:1 under either, which is why the "
                           + "grey is the one that tells them apart")
    }

    /// The accent is used as a background with `onAccent` on top, so the two
    /// have to be far enough apart to read.
    func testAccentAndItsForegroundAreFarApart() {
        XCTAssertGreaterThan(contrast(Palette.accent, Palette.onAccent), 4.5,
                             "accent text would be hard to read on the accent colour")
    }

    /// And the accent has to be visible ON the window, not only under its
    /// own text: it is the line around the window and the fill of the
    /// primary button.
    func testTheAccentStandsOutFromTheBackground() {
        XCTAssertGreaterThan(contrast(Palette.accent, Palette.background), 3,
                             "the accent does not separate from the window "
                                 + "it is drawn on")
    }

    /// The three status colours are a traffic light, so no two of them may
    /// be mistakable -- and the accent must not be mistakable for the one
    /// that means something failed.
    func testTheTrafficLightAndTheAccentAreTellableApart() {
        for (name, one, other) in [
            ("ok/busy", Palette.ok, Palette.busy),
            ("ok/error", Palette.ok, Palette.error),
            ("busy/error", Palette.busy, Palette.error),
            ("error/accent", Palette.error, Palette.accent),
        ] {
            XCTAssertGreaterThan(
                Self.distance(one, other), 60,
                "\(name) are too close to tell apart: \(one) and \(other)")
        }
    }

    /// Straight-line distance in RGB. Crude on purpose: the question is only
    /// whether two lamps could be confused at a glance, not how a colour
    /// scientist would rank them.
    private static func distance(_ one: String, _ other: String) -> Double {
        let a = bytes(one), b = bytes(other)
        var total = 0.0
        for index in 0..<3 {
            let difference = Double(a[index]) - Double(b[index])
            total += difference * difference
        }
        return total.squareRoot()
    }

    private static func bytes(_ hex: String) -> [Int] {
        let digits = Array(hex.dropFirst())
        var out: [Int] = []
        for offset in stride(from: 0, to: 6, by: 2) {
            out.append(Int(String(digits[offset...(offset + 1)]), radix: 16) ?? 0)
        }
        return out
    }

    /// Body text on the window background, the pairing most of the interface
    /// is made of.
    func testTextOnBackgroundIsReadable() {
        XCTAssertGreaterThan(contrast(Palette.text, Palette.background), 7,
                             "body text does not reach AAA on the background")
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
