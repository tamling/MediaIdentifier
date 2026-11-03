import XCTest
@testable import MediaIdentifierCore

/// Tests the one property `AtomicFile` exists for: a write either replaces the
/// file completely or changes nothing at all.
///
/// This used to be delete-the-destination-then-move, which has neither half of
/// that property — there was a window with no file, and a move that failed
/// afterwards left the old contents destroyed. For `secrets.json` that is every
/// stored API key.
final class AtomicFileTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func permissions(of url: URL) throws -> Int16 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).int16Value
    }

    func testWritesANewFileWithTheRequestedPermissions() throws {
        let target = directory.appendingPathComponent("new.json")
        try AtomicFile.write(Data("first".utf8), to: target, permissions: 0o600)

        XCTAssertEqual(try Data(contentsOf: target), Data("first".utf8))
        XCTAssertEqual(try permissions(of: target) & 0o777, 0o600)
    }

    /// Replacing must keep the tight permissions, not inherit the umask.
    func testReplacingKeepsTheContentAndThePermissions() throws {
        let target = directory.appendingPathComponent("replace.json")
        try AtomicFile.write(Data("first".utf8), to: target, permissions: 0o600)
        try AtomicFile.write(Data("second".utf8), to: target, permissions: 0o600)

        XCTAssertEqual(try Data(contentsOf: target), Data("second".utf8))
        XCTAssertEqual(try permissions(of: target) & 0o777, 0o600)
    }

    /// The regression test for the data-loss bug.
    ///
    /// A directory at the destination makes the replacement fail. The old code
    /// called `removeItem` on the destination first, which deleted that
    /// directory **and everything in it** before discovering it could not
    /// finish. `rename` simply fails and touches nothing.
    func testAFailedWriteDestroysNothing() throws {
        let target = directory.appendingPathComponent("occupied.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bystander = target.appendingPathComponent("precious.txt")
        try Data("do not delete me".utf8).write(to: bystander)

        XCTAssertThrowsError(try AtomicFile.write(Data("new".utf8), to: target,
                                                  permissions: 0o600)) { error in
            XCTAssertEqual(error as? SettingsStore.Failure, .notWritable(target.path))
        }

        // Everything that was there before is still there.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: bystander), Data("do not delete me".utf8))
    }

    /// And it must not leave its scratch file behind for the next run to trip
    /// over, nor for a backup to pick up.
    func testAFailedWriteLeavesNoTemporaryBehind() throws {
        let target = directory.appendingPathComponent("occupied.json")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        XCTAssertThrowsError(try AtomicFile.write(Data("new".utf8), to: target,
                                                  permissions: 0o600))

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, ["occupied.json"],
                       "a scratch file survived a failed write: \(left)")
    }

    func testASuccessfulWriteLeavesNoTemporaryBehind() throws {
        let target = directory.appendingPathComponent("clean.json")
        try AtomicFile.write(Data("x".utf8), to: target, permissions: 0o600)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path),
                       ["clean.json"])
    }

    /// A stale scratch file from a previous crash must not block the next write.
    func testAStaleTemporaryFromAnEarlierCrashIsReplaced() throws {
        let target = directory.appendingPathComponent("settings.json")
        let stale = directory.appendingPathComponent(".settings.json.tmp")
        try Data("left over".utf8).write(to: stale)

        try AtomicFile.write(Data("fresh".utf8), to: target, permissions: 0o600)

        XCTAssertEqual(try Data(contentsOf: target), Data("fresh".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testCreatesTheDirectoryWhenItIsMissing() throws {
        let nested = directory.appendingPathComponent("a/b/c/settings.json")
        try AtomicFile.write(Data("deep".utf8), to: nested, permissions: 0o600)

        XCTAssertEqual(try Data(contentsOf: nested), Data("deep".utf8))
    }

    /// The property that matters most and is hardest to observe: a reader never
    /// sees the file absent while it is being replaced. Approximated by
    /// hammering a reader against a writer — with delete-then-move this fails
    /// quickly, because the gap between the two calls is wide enough to hit.
    func testTheFileIsNeverMissingWhileBeingReplaced() throws {
        let target = directory.appendingPathComponent("hot.json")
        try AtomicFile.write(Data("0".utf8), to: target, permissions: 0o600)

        let writes = 200
        let reader = expectation(description: "reader finished")
        let state = NSLock()
        var sawMissing = false
        var writingFinished = false
        var reads = 0

        // The reader runs until the writer says it is done, rather than for a
        // fixed number of turns: a fixed count can finish before the first
        // write lands, and the test would then pass having observed nothing.
        DispatchQueue.global().async {
            while true {
                let missing = FileManager.default.contents(atPath: target.path) == nil
                state.lock()
                reads += 1
                if missing { sawMissing = true }
                let stop = missing || writingFinished
                state.unlock()
                if stop { break }
            }
            reader.fulfill()
        }

        for index in 1...writes {
            try AtomicFile.write(Data("\(index)".utf8), to: target, permissions: 0o600)
        }
        state.lock(); writingFinished = true; state.unlock()
        wait(for: [reader], timeout: 30)

        state.lock()
        let missing = sawMissing
        let observed = reads
        state.unlock()
        XCTAssertFalse(missing, "the file vanished while it was being replaced")
        // Guards against the test passing because the reader never ran.
        XCTAssertGreaterThan(observed, writes,
                             "the reader did not sample often enough to mean anything")
    }
}
