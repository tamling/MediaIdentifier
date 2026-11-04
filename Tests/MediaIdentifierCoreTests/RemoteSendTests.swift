import XCTest
@testable import MediaIdentifierCore

/// Sending the proposals to the remote library.
///
/// The transfer itself is tested against a real SSH server in
/// `RemoteTransferIntegrationTests`. What is checked here is everything the
/// coordinator decides *before* a byte moves — which is where the damage
/// would be done: sending with half a configuration, sending what was not
/// ticked, or deleting a local file because a cancelled run looked finished.
final class RemoteSendTests: XCTestCase {

    private var root: URL!
    private var coordinator: AppCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"),
                                                withIntermediateDirectories: true)
        coordinator = AppCoordinator(configDirectory: root.appendingPathComponent("config"))
    }

    override func tearDownWithError() throws {
        coordinator = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func enableRemote(_ change: (inout RemoteTarget) -> Void = { _ in }) {
        var settings = coordinator.settings
        var target = RemoteTarget(isEnabled: true, host: "nas.local", port: 22,
                                  user: "media", basePath: "/srv/media")
        change(&target)
        settings.remote = target
        coordinator.executeForTesting(.saveSettings(settings))
    }

    // MARK: What goes where

    /// The whole point of the feature: the file is sent under the name and
    /// into the folders the proposal worked out, not under its own name.
    func testTheFileIsSentToItsProposedPath() throws {
        let item = Self.item(source: "/downloads/Dark.S01E01.GERMAN.1080p.mkv",
                             relative: "Dark/Staffel 01/Dark - S01E01.mkv")
        let sends = AppCoordinator.remoteTransfers(for: item)
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends[0].relative, "Dark/Staffel 01/Dark - S01E01.mkv")
        XCTAssertEqual(sends[0].local.path, "/downloads/Dark.S01E01.GERMAN.1080p.mkv")
    }

    /// Subtitles travel with the episode. A subtitle that stayed behind is a
    /// subtitle the media server will never find.
    func testCompanionsFollowTheEpisodeIntoTheSameFolder() throws {
        var item = Self.item(source: "/downloads/Dark.S01E01.mkv",
                             relative: "Dark/Staffel 01/Dark - S01E01.mkv")
        item.companionMoves = [
            PlannedMove(source: URL(fileURLWithPath: "/downloads/Dark.S01E01.ger.srt"),
                        destination: URL(fileURLWithPath:
                            "/library/Dark/Staffel 01/Dark - S01E01.ger.srt")),
        ]
        let sends = AppCoordinator.remoteTransfers(for: item)
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends[1].relative, "Dark/Staffel 01/Dark - S01E01.ger.srt")
        XCTAssertEqual(sends[1].local.path, "/downloads/Dark.S01E01.ger.srt")
    }

    /// A film proposed at the top of the library has no folder to join; the
    /// companion must not end up at "/name".
    func testACompanionOfAFileWithNoFolderKeepsItsBareName() {
        var item = Self.item(source: "/downloads/Rosenheim.mkv", relative: "Rosenheim.mkv")
        item.companionMoves = [
            PlannedMove(source: URL(fileURLWithPath: "/downloads/Rosenheim.srt"),
                        destination: URL(fileURLWithPath: "/library/Rosenheim.srt")),
        ]
        let sends = AppCoordinator.remoteTransfers(for: item)
        XCTAssertEqual(sends[1].relative, "Rosenheim.srt")
    }

    // MARK: Refusing to start

    func testSendingWithTheServerSwitchedOffDoesNothing() {
        coordinator.executeForTesting(.transferFiles(accepting: [UUID()]))
        XCTAssertEqual(coordinator.snapshot.lastResult,
                       "Der Server ist in den Einstellungen nicht aktiviert.")
        XCTAssertFalse(coordinator.snapshot.transferring)
    }

    /// Half a configuration must stop the run at the start. Finding out after
    /// the third file means a library split across two machines.
    func testAnIncompleteServerConfigurationStopsBeforeAnythingIsSent() {
        enableRemote { $0 = RemoteTarget(isEnabled: true, host: "", user: "",
                                         basePath: "relative/path") }
        coordinator.executeForTesting(.transferFiles(accepting: [UUID()]))
        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("unvollständig"), result)
        XCTAssertTrue(coordinator.snapshot.hasError)
    }

    /// Password login with no password stored: the tools would sit waiting
    /// for a prompt nobody can answer.
    func testPasswordLoginWithoutAStoredPasswordIsRefused() {
        enableRemote { $0.authentication = .password }
        coordinator.executeForTesting(.transferFiles(accepting: [UUID()]))
        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("kein"), result)
        XCTAssertTrue(coordinator.snapshot.hasError)
    }

    /// An empty tick list means the user unticked everything, which must send
    /// nothing rather than everything.
    func testAnEmptySelectionSendsNothing() {
        enableRemote()
        coordinator.executeForTesting(.transferFiles(accepting: []))
        XCTAssertEqual(coordinator.snapshot.lastResult,
                       "Es war nichts angehakt, also wurde nichts gesendet.")
    }

    /// The configuration is only reported as usable when it is complete, so
    /// the interface does not offer a button that cannot work.
    func testTheStatusSaysWhetherTheServerIsUsable() {
        XCTAssertFalse(coordinator.snapshot.remoteConfigured,
                       "nothing is configured yet")

        enableRemote { $0.basePath = "" }
        XCTAssertFalse(coordinator.snapshot.remoteConfigured,
                       "a server with no target path cannot be used")

        enableRemote()
        XCTAssertTrue(coordinator.snapshot.remoteConfigured)

        // Switching it off has to take effect at once, not at the next scan.
        enableRemote { $0.isEnabled = false }
        XCTAssertFalse(coordinator.snapshot.remoteConfigured)
    }

    // MARK: Cancelling

    /// The same bug the converter had: a cancel that arrives while the run is
    /// still queued belongs to that run.
    func testACancelThatArrivesBeforeTheSendStartsIsKept() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)

        coordinator.submit(.transferFiles(accepting: [UUID()]))
        coordinator.submit(.cancelTransfers)

        XCTAssertTrue(coordinator.transferCancelIsArmedForTesting,
                      "a cancel for a send that has not started yet must be remembered")
        XCTAssertEqual(coordinator.snapshot.lastResult, "Stoppt vor der nächsten Datei.")

        gate.signal()
        coordinator.drainForTesting()
    }

    func testACancelWhileNothingIsSendingIsNotRemembered() {
        coordinator.submit(.cancelTransfers)
        XCTAssertFalse(coordinator.transferCancelIsArmedForTesting)
        XCTAssertEqual(coordinator.snapshot.lastResult, "Es läuft keine Übertragung.")
    }

    /// Cancelling a send must not stop a conversion, and the other way round:
    /// they are two buttons and two runs.
    func testTheTwoCancelsAreIndependent() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)

        coordinator.submit(.transferFiles(accepting: [UUID()]))
        coordinator.submit(.cancelTransfers)

        XCTAssertTrue(coordinator.transferCancelIsArmedForTesting)
        XCTAssertFalse(coordinator.cancelIsArmedForTesting,
                       "stopping a transfer must not stop a conversion")

        gate.signal()
        coordinator.drainForTesting()
    }

    /// A refused start must not leave the flag armed, or the next send the
    /// user asks for would stop before its first file.
    func testARefusedSendDoesNotLeaveACancelArmed() {
        let gate = DispatchSemaphore(value: 0)
        coordinator.blockQueueForTesting(until: gate)
        coordinator.submit(.transferFiles(accepting: [UUID()]))
        coordinator.submit(.cancelTransfers)
        gate.signal()
        coordinator.drainForTesting()

        XCTAssertFalse(coordinator.transferCancelIsArmedForTesting,
                       "the flag must be cleared when the run it belonged to ends")
    }

    // MARK: Settings

    /// Off by default. Nobody's recording is deleted because a default said
    /// so — the user has to ask for it.
    func testTheLocalCopyIsKeptUnlessAskedOtherwise() {
        XCTAssertFalse(RemoteTarget().removeLocalAfterSend)
        XCTAssertFalse(coordinator.settings.remote.removeLocalAfterSend)
    }

    /// A form that does not carry the server section must leave it alone,
    /// otherwise saving the conversion page would wipe the server.
    func testAFormWithoutTheServerSectionKeepsIt() {
        let stored = RemoteTarget(isEnabled: true, host: "nas.local", port: 2222,
                                  user: "media", basePath: "/srv/media",
                                  transport: .sftp, authentication: .password)
        let unchanged = RemoteTarget.fromForm(["videoCodec": "h264"], current: stored)
        XCTAssertEqual(unchanged, stored)
    }

    /// An unticked checkbox sends nothing at all, so the hidden companion
    /// field is what tells "unticked" from "not in this form".
    func testTheCheckboxesNeedTheirCompanionField() {
        let on = RemoteTarget(isEnabled: true, host: "nas.local", user: "media",
                              basePath: "/srv/media", removeLocalAfterSend: true)
        XCTAssertTrue(RemoteTarget.fromForm([:], current: on).isEnabled)

        let off = RemoteTarget.fromForm(["remoteEnabledPresent": "1",
                                         "remoteRemoveLocalPresent": "1"], current: on)
        XCTAssertFalse(off.isEnabled)
        XCTAssertFalse(off.removeLocalAfterSend)

        let backOn = RemoteTarget.fromForm(["remoteEnabledPresent": "1",
                                            "remoteEnabled": "on"], current: off)
        XCTAssertTrue(backOn.isEnabled)
    }

    /// A port that is not a number keeps the stored one. Silently falling
    /// back to 22 would send the library to whatever answers there.
    func testANonNumericPortKeepsTheStoredOne() {
        let stored = RemoteTarget(isEnabled: true, host: "nas.local", port: 2222,
                                  user: "media", basePath: "/srv/media")
        XCTAssertEqual(RemoteTarget.fromForm(["remotePort": "zweitausend"],
                                             current: stored).port, 2222)
        XCTAssertEqual(RemoteTarget.fromForm(["remotePort": "2200"],
                                             current: stored).port, 2200)
    }

    // MARK: Two files, one destination

    /// Two rips of the same episode resolve to the same remote path. Sent,
    /// one lands on top of the other and the user has one file where they
    /// had two — and with "delete the local copy" on, both originals are
    /// gone. Which to keep is not a decision this code should make.
    func testProposalsThatCollideOnTheServerAreRefusedRatherThanOverwritten() {
        enableRemote()
        let a = Self.item(source: "/downloads/Dark.S01E01.1080p.mkv",
                          relative: "Dark/Staffel 01/Dark - S01E01.mkv")
        let b = Self.item(source: "/downloads/Dark.S01E01.720p.mkv",
                          relative: "Dark/Staffel 01/Dark - S01E01.mkv")
        coordinator.setItemsForTesting([a, b])

        coordinator.executeForTesting(.transferFiles(accepting: [a.id, b.id]))

        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("dieselbe Stelle"), result)
        XCTAssertTrue(result.contains("Dark.S01E01.1080p.mkv"), result)
        XCTAssertTrue(result.contains("Dark.S01E01.720p.mkv"), result)
        XCTAssertTrue(coordinator.snapshot.hasError)
        // Neither was sent, so neither left the list.
        XCTAssertEqual(coordinator.items.count, 2)
    }

    /// Only the colliding pair is held back; anything else still goes.
    func testOnlyTheCollidingProposalsAreHeldBack() {
        enableRemote()
        let a = Self.item(source: "/downloads/Dark.S01E01.1080p.mkv",
                          relative: "Dark/Staffel 01/Dark - S01E01.mkv")
        let b = Self.item(source: "/downloads/Dark.S01E01.720p.mkv",
                          relative: "Dark/Staffel 01/Dark - S01E01.mkv")
        let c = Self.item(source: "/downloads/Dark.S01E02.1080p.mkv",
                          relative: "Dark/Staffel 01/Dark - S01E02.mkv")
        coordinator.setItemsForTesting([a, b, c])

        coordinator.executeForTesting(.transferFiles(accepting: [a.id, b.id, c.id]))

        // The third one was attempted — it fails for want of a real server,
        // which is fine; what matters is that it was not held back with the
        // other two.
        XCTAssertTrue(coordinator.logEntries.contains {
            $0.oldName == "Dark.S01E02.1080p.mkv"
        }, "a proposal that collided with nothing was held back too")
        XCTAssertFalse(coordinator.logEntries.contains {
            $0.oldName.contains("720p")
        }, "a colliding proposal was sent anyway")
    }

    // MARK: A probe describes one particular server

    /// Change the address and the stored answer is about a different
    /// machine. It used to be kept, so the lamp could be green about a
    /// server nobody had ever contacted.
    func testChangingTheServerThrowsAwayTheProbeItWasAbout() {
        enableRemote()
        coordinator.recordProbeForTesting(.remote, ok: true, detail: "Angemeldet.")
        XCTAssertTrue(coordinator.systemChecks.contains { $0.id == "remote" && $0.state == .ok })

        enableRemote { $0.host = "something-else.local" }
        let lamp = coordinator.systemChecks.first { $0.id == "remote" }
        XCTAssertEqual(lamp?.state, .warning,
                       "the old server's green lamp survived the address changing")
    }

    /// And when the credential changes, because the probe was made with the
    /// previous one.
    func testChangingThePasswordThrowsAwayTheProbe() {
        enableRemote { $0.authentication = .password }
        coordinator.executeForTesting(.setSecret(.remotePassword, "first"))
        coordinator.recordProbeForTesting(.remote, ok: true, detail: "Angemeldet.")

        coordinator.executeForTesting(.setSecret(.remotePassword, "second"))
        XCTAssertEqual(coordinator.systemChecks.first { $0.id == "remote" }?.state, .warning,
                       "a probe made with the old password still reads as green")
    }

    /// Saving something unrelated must not throw away a good answer, or the
    /// panel would be permanently amber.
    func testAnUnrelatedSettingKeepsTheProbe() {
        enableRemote()
        coordinator.recordProbeForTesting(.remote, ok: true, detail: "Angemeldet.")

        var settings = coordinator.settings
        settings.conflictPolicy = .rename
        coordinator.executeForTesting(.saveSettings(settings))

        XCTAssertEqual(coordinator.systemChecks.first { $0.id == "remote" }?.state, .ok,
                       "an unrelated save discarded a good probe")
    }

    // MARK: Helpers

    private static func item(source: String, relative: String) -> RenameItem {
        let url = URL(fileURLWithPath: source)
        let parsed = ParsedRelease(originalFileName: url.lastPathComponent,
                                   title: "Whatever", kind: .episode)
        return RenameItem(mediaFile: MediaFile(url: url, parsed: parsed),
                          outputRoot: URL(fileURLWithPath: "/library", isDirectory: true),
                          proposedRelativePath: relative)
    }
}
