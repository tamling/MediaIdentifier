import XCTest
@testable import MediaIdentifierCore

final class WatchFolderScannerTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: dir) }

    private func write(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0, count: bytes).write(to: url)
        return url
    }

    // FR20 — a file is only reported once its size has stabilised.
    func testReportsOnlyStableFiles() throws {
        let scanner = WatchFolderScanner()
        let url = try write("Movie.2020.1080p.mkv", bytes: 100)

        // First poll: file is new, not yet stable.
        XCTAssertTrue(scanner.poll(directory: dir).isEmpty)

        // Still growing -> not reported.
        try Data(repeating: 0, count: 200).write(to: url)
        XCTAssertTrue(scanner.poll(directory: dir).isEmpty)

        // Size unchanged -> reported once.
        let reported = scanner.poll(directory: dir)
        XCTAssertEqual(reported.map { $0.lastPathComponent }, ["Movie.2020.1080p.mkv"])

        // Not reported again.
        XCTAssertTrue(scanner.poll(directory: dir).isEmpty)
    }

    func testIgnoresNonVideo() throws {
        let scanner = WatchFolderScanner()
        _ = try write("notes.txt", bytes: 10)
        _ = scanner.poll(directory: dir)
        XCTAssertTrue(scanner.poll(directory: dir).isEmpty)
    }
}
