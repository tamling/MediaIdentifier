import Foundation

/// The version, defined once.
///
/// `tools/build-deb.sh` reads this file rather than carrying its own number,
/// so the package and the window can never disagree about which version is
/// running — which is the sort of thing nobody checks until a bug report
/// names a version that was never built.
public enum MediafinVersion {
    /// Three dot-separated numbers, nothing else. The Debian package appends
    /// its own build metadata (`~gitYYYYMMDD.<sha>`), which has to stay out of
    /// here or the script cannot compose it.
    public static let number = "1.0.0"

    /// What the interface shows.
    public static var display: String { "Mediafin \(number)" }
}
