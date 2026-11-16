import Foundation

/// The one line under the window title: what the program is doing right now.
///
/// In Core and not in the GTK front-end because of what it is: a rule about
/// which numbers may be shown, and the only way to check it in the window was
/// to put the engine into the state in question and photograph the result.
/// The check that was supposed to cover the interesting half of this rule ran
/// in a state where the fault could not occur -- `busy` false, where the code
/// before and after the fix behave identically -- so the rule had no test
/// that could fail. Here it is a pure function of the snapshot, and the
/// states that matter are three lines of test each.
public enum HeaderSubtitle {

    /// - Returns: the subtitle for `state`, in the current language.
    public static func text(for state: StatusSnapshot) -> String {
        guard state.isWorking else {
            return state.hasError
                ? Text.s("Mit Fehlern beendet", "Finished with errors")
                : Text.s("Bereit", "Ready")
        }
        // Two kinds of working. `busy` is set by the handlers that report
        // progress; `isWorking` also covers the commands that hold the
        // engine's serial queue without ever setting it -- Rückgängig, both
        // connection tests, and Alles prüfen. A probe against an unreachable
        // server holds the queue for the 30-second request timeout, and
        // Alles prüfen runs two of them.
        //
        // A percentage only from a job that measures one. `activePercent` is
        // `converting ? convertProgress : renameProgress` and has no notion
        // of "this job reports nothing", while `renameProgress` is set to 1
        // at the end of every rename and never reset. So a download -- which
        // sets `busy` and reports into `downloadProgress` -- made the header
        // read "Arbeitet · 100 %" from the first instant of a fetch, while
        // the panel's own bar beside it read 3 %. Suchen over a large
        // library did the same.
        if state.converting || state.renaming {
            return (state.convertStatus ?? Text.s("Arbeitet", "Working"))
                + " · \(state.activePercent) %"
        }
        if state.busy {
            return state.convertStatus ?? Text.s("Arbeitet …", "Working…")
        }
        return Text.s("Arbeitet …", "Working…")
    }
}
