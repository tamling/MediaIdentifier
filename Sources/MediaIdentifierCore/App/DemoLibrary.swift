import Foundation

/// A throwaway library of plausible files, for looking at the interface with
/// something in it.
///
/// It creates real files in a temporary directory and lets the real scanner,
/// parser and planner run over them. That matters: a screenshot filled with
/// hand-written strings would prove only that labels can hold text, while
/// this one fails if the parser stops recognising a release name or the
/// planner stops producing a destination. What ends up on screen is what the
/// pipeline actually produced.
///
/// Identification stays offline. The demo must not depend on a network or on
/// anyone's API key, and filename parsing alone is enough to show the shape
/// of the result.
public enum DemoLibrary {

    /// Names chosen to cover what the parser has to survive, not to look
    /// tidy: a plain film, a 4K release with a long tag list, two series
    /// episodes, a German release, a title containing an ampersand — which is
    /// the one that breaks Pango markup if the escaping is ever dropped — and
    /// a file that already looks converted.
    public static let fileNames = [
        "The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv",
        "Arrival.2016.2160p.UHD.BluRay.DTS-HD.MA.7.1.x265-TERMiNAL.mkv",
        "Fear.and.Loathing.in.Las.Vegas.1998.1080p.BluRay.x264.mkv",
        "Breaking.Bad.S03E07.One.Minute.1080p.WEB-DL.DD5.1.H.264.mkv",
        "Breaking.Bad.S03E08.I.See.You.1080p.WEB-DL.DD5.1.H.264.mkv",
        "Dark.S01E01.Geheimnisse.German.DL.1080p.NF.WEB-DL.x264.mkv",
        "Der.Name.der.Rose.1986.German.DL.1080p.BluRay.x264-DETAiLS.mkv",
        "Sense.and.Sensibility.1995.720p.BluRay.x264.mkv",
    ]

    /// Where the demo put its files, so the caller can clean up.
    public struct Layout: Sendable {
        public let root: URL
        public let source: URL
        public let movies: URL
        public let series: URL
    }

    /// Creates the files and returns where they are.
    ///
    /// - Parameter parent: where to put the root; a temporary directory by
    ///   default. The caller owns it and should delete it afterwards.
    public static func create(
        in parent: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> Layout {
        let root = parent.appendingPathComponent("mediafin-demo-\(UUID().uuidString)",
                                                 isDirectory: true)
        let layout = Layout(
            root: root,
            source: root.appendingPathComponent("Downloads", isDirectory: true),
            movies: root.appendingPathComponent("Movies", isDirectory: true),
            series: root.appendingPathComponent("Series", isDirectory: true)
        )
        for directory in [layout.source, layout.movies, layout.series] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in fileNames {
            let url = layout.source.appendingPathComponent(name)
            // A few hundred bytes rather than an empty file: a zero-length
            // file is the one thing a scanner is entitled to skip.
            try Data(repeating: 0, count: 4096).write(to: url)
        }
        return layout
    }

    /// Settings pointing at a created layout.
    public static func settings(for layout: Layout) -> WebSettings {
        var settings = WebSettings()
        settings.sourceFolder = layout.source.path
        settings.moviesFolder = layout.movies.path
        settings.seriesFolder = layout.series.path
        // No network, no credentials.
        settings.identification = .offline
        settings.watchSourceFolder = false
        // Filled in but switched off. The server fields then have something
        // in them in a screenshot, and nothing in the demo can reach a
        // network: an enabled target would have the status panel trying to
        // log in to a machine that does not exist.
        settings.remote = RemoteTarget(isEnabled: false,
                                       host: "nas.fritz.box",
                                       port: 22,
                                       user: "mediafin",
                                       basePath: "/volume1/Medien")
        return settings
    }
}
