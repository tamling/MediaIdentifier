import SwiftUI
import AppKit

/// The empty-state drop target shown when the queue is empty (FR1, FR19).
struct EmptyDropView: View {
    @EnvironmentObject private var state: AppState
    @State private var pulse = false

    private let formats = ["MKV", "MP4", "AVI", "MOV", "M4V", "SRT"]

    var body: some View {
        // The dashed drop area fills the whole pane and scales with the window.
        Button(action: chooseFiles) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                iconBadge
                Text("Drag files here")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 22)
                Text("Single movies, whole seasons or complete folders.\nRelease names are analyzed automatically.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(hex: 0x9A9AA0))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 8)
                chips.padding(.top, 22)
                Text("or choose files →")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.accentBright)
                    .padding(.top, 26)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .foregroundStyle(Color.white.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .padding(24)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 2)
                .frame(width: 84, height: 84)
                .scaleEffect(pulse ? 1.35 : 1)
                .opacity(pulse ? 0 : 0.5)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x14352C), Color(hex: 0x0E231D)],
                        center: .init(x: 0.5, y: 0.35), startRadius: 2, endRadius: 50
                    )
                )
                .frame(width: 84, height: 84)
                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 0.5))
                .overlay(
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Theme.accentBright)
                        .offset(y: -2)
                )
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    private var chips: some View {
        HStack(spacing: 7) {
            ForEach(formats, id: \.self) { fmt in
                Text(fmt)
                    .font(.system(size: 11, weight: .bold)).tracking(0.4)
                    .foregroundStyle(Color(hex: 0x9A9AA0))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            state.importURLs(panel.urls)
        }
    }
}
