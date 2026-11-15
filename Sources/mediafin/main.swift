import Foundation
import MediaIdentifierCore

// Mediafin's headless runner.
//
// All this does is hold the engine so its own schedule timer can fire. There
// is no interface here: the window is `mediafin-gtk`, and the terminal and web
// front-ends are gone.
//
// It exists because the schedule has to work when the window is closed. The
// timer lives inside AppCoordinator, so any process holding one runs it — but
// a process has to be there. This is that process, and the systemd unit in
// tools/build-deb.sh starts it.

private func usage() -> String {
    """
    mediafin — Mediafin's headless runner, version \(MediafinVersion.number)

      mediafin --watch      hold the engine so scheduled runs happen while
                            the window is closed. This is what the systemd
                            service starts; it does not exit on its own.
      mediafin --once       do whatever the schedule says is due, then exit.
                            For a cron line of your own.
      mediafin --version    print the version
      mediafin --help       this text

    The interface is mediafin-gtk. This command draws nothing.
    """
}

private let arguments = Array(CommandLine.arguments.dropFirst())

// No arguments is not "start something sensible": with no interface in here
// there is nothing sensible to start, and a command that silently does nothing
// is worse than one that says what it offers.
guard arguments.count == 1, let mode = arguments.first else {
    print(usage())
    exit(64)
}

/// Keeps the signal sources alive for the whole process.
///
/// Not a local: see `--watch` below. A released source is a cancelled
/// source, and with the default action set to SIG_IGN the signal is then
/// ignored and the service cannot be stopped.
enum StopSignals {
    private static var sources: [DispatchSourceSignal] = []

    /// Stops the process cleanly on SIGTERM and SIGINT, running `before`
    /// first. Returns once the handlers are armed.
    static func install(before: @escaping @Sendable () -> Void) {
        sources = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler {
                before()
                exit(0)
            }
            source.resume()
            return source
        }
    }
}

switch mode {
case "--help", "-h":
    print(usage())
case "--version":
    print(MediafinVersion.display)
case "--once":
    let coordinator = AppCoordinator(configDirectory: MediafinPaths.configDirectory())
    // Returns only once the work is finished, so the process does not exit
    // in the middle of a rename it has just started.
    coordinator.runDueWorkNow()
    // And the history reaches the disk before the process goes. Its writes
    // are coalesced with a trailing write, which needs somebody to still be
    // running when it fires; exiting here used to drop the tail of the one
    // record an unattended run leaves behind.
    coordinator.flushToDisk()
case "--watch":
    let coordinator = AppCoordinator(configDirectory: MediafinPaths.configDirectory())
    // The timer is already running inside the coordinator; this thread only
    // has to stay alive. dispatchMain never returns, which is exactly right
    // for a service, and parks the thread rather than spinning.
    //
    // `systemctl stop` sends SIGTERM, whose default action is to end the
    // process on the spot. Taken through a Dispatch source rather than
    // `signal(2)`: the handler then runs on an ordinary queue, where it may
    // take locks and write files, which a real signal handler may not.
    // Without this the service lost the tail of its history on every stop.
    //
    // Held in a global, and that is not a style choice. A
    // DispatchSourceSignal that is released is cancelled, and the default
    // action is already SIG_IGN by then — so the process would ignore
    // SIGTERM outright and never stop at all. In a debug build the local
    // happened to stay alive and this worked; in a release build the
    // optimiser dropped it, `--watch` became unkillable by SIGTERM, and the
    // smoke test's `wait` hung for six hours instead of failing.
    StopSignals.install { coordinator.flushToDisk() }
    _ = coordinator
    dispatchMain()
default:
    FileHandle.standardError.write(Data(
        ("mediafin: unknown option \(mode)\n\n" + usage() + "\n").utf8))
    exit(64)
}
