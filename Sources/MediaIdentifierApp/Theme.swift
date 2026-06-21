import SwiftUI

/// Colour palette and reusable styling for the Mediafin design.
enum Theme {
    // Surfaces
    static let windowBg      = Color(hex: 0x1B1B1D)
    static let titleBarTop   = Color(hex: 0x262628)
    static let titleBarBot   = Color(hex: 0x222224)
    static let sidebarBg     = Color.white.opacity(0.022)
    static let hairline      = Color.white.opacity(0.06)
    static let hover         = Color.white.opacity(0.05)
    static let chipBg        = Color.white.opacity(0.06)

    // Accent (Jellyfin green)
    static let accent        = Color(hex: 0x00A878)
    static let accentBright  = Color(hex: 0x1FC98F)
    static let accentGlow    = Color(hex: 0x00C98E)

    // Text
    static let textPrimary   = Color(hex: 0xF5F5F7)
    static let textRow       = Color(hex: 0xC8C8CD)
    static let textSecondary = Color(hex: 0x8A8A90)
    static let textTertiary  = Color(hex: 0x6E6E76)
    static let mono          = Color(hex: 0x86868C)

    // Type accents
    static let series        = Color(hex: 0xB89CFF)
    static let movie         = Color(hex: 0x7FB3FF)
    static let warn          = Color(hex: 0xE6A23C)

    static let seriesBg      = Color(hex: 0x966EFF).opacity(0.13)
    static let movieBg       = Color(hex: 0x508CFF).opacity(0.13)

    static let monoFont = Font.system(size: 12.5, design: .monospaced)
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A pill/chip used throughout the row metadata.
struct Chip: View {
    let text: String
    var fg: Color = Theme.textRow
    var bg: Color = Theme.chipBg
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.3)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bg, in: RoundedRectangle(cornerRadius: 6))
    }
}
