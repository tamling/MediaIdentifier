import SwiftUI

/// TMDb online lookup settings (FR3). Lets the user enable online identification
/// and supply a free TMDb API key. When disabled, the app stays fully local (FR18).
struct MetadataSettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Online Metadata (TMDb)")
                .font(.headline)

            Toggle("Look up official titles online", isOn: $state.onlineLookupEnabled)
                .help("When on, parsed titles are confirmed against TMDb.")

            VStack(alignment: .leading, spacing: 4) {
                Text("TMDb API Key")
                    .font(.subheadline)
                SecureField("Enter your TMDb API key", text: $state.tmdbAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!state.onlineLookupEnabled)
                Text("Get a free key at themoviedb.org → Settings → API. Only the parsed title and year are sent — never any media file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    state.lookUpOnline()
                } label: {
                    if state.isLookingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Look Up Now")
                    }
                }
                .disabled(!state.canLookUpOnline || state.isLookingUp)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
