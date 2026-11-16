#!/usr/bin/env python3
"""Fail the build when an engine command has no sender.

The fault this exists for, in full: of the eighteen commands
`AppCoordinator` accepts, five had no sender anywhere in the program.
`findConvertible`, `convertFiles` and `cancelConversions` -- the whole
conversion feature, with its FFmpeg driving, its progress reporting, its
cancelling, its size estimation and all of their tests -- were in the
binary with no button that could ask for any of them. So was
`testJellyfinConnection`, whose address field did not exist either. So was
`clearHistory`.

They had been reachable from a web front-end that was removed. Nothing
noticed: the engine's own tests call `executeForTesting` directly, so every
one of those paths was green, and the traffic light cheerfully reported
"Gefunden -- Konvertieren ist moeglich" about a feature with no entrance.

A unit test cannot find this. Reading the code does not find it either --
an audit of 38 findings read every one of those handlers and asked whether
they were right, which they were. What finds it is asking the opposite
question: does anything ever send this?

The rule looks for a SEND, not a mention.

The first version of this matched the bare substring `.commandName`
anywhere in a front end, which it called "deliberately crude" and argued
was safe because a false pass would need somebody to write `.convertFiles`
without wiring it up. That argument was already wrong in the tree it
shipped in: the window names four of its own private methods exactly after
the commands they send -- `findConvertible()`, `clearHistory()`,
`checkEverything()`, `cancelDownload()` -- and `{ $0.clearHistory() }`
matches `.clearHistory` on its own. So four of the eighteen could never be
reported, two of them among the five dead commands whose discovery is the
reason this file exists. Deleting the `submit` inside `clearHistory()`
still printed "ok : all 18 engine commands have a sender".

So the needle is the send itself. Both spellings count: `submit(.name)`
goes straight to the engine, and `start(.name)` is the window's wrapper,
which submits and then shuts the buttons the work gates. A THIRD wrapper
added later and not listed here makes this check FAIL rather than pass,
which is the direction a mistake has to fall in.

The second rule is about WHICH of those two the window uses.

The gates live in `refresh()`, which a 500 ms timer calls -- so a handler
that only submits leaves every gated button live for up to half a second
after the press that started the work, which is where the Rückgängig
double-click landed and reversed a batch nobody asked about. `start()`
closes them at press time, and that is the only reason it exists.

The smoke check that watches this presses Alles prüfen and reads the two
gates with no refresh in between. It proves that `start()` still refreshes
-- but it presses ONE of the ten call sites, so unwiring `refresh()` from
`undoLast()` alone (by going back to a bare `submit`) leaves it green;
measured. So: from the window, every command that sets work in motion must
be sent through `start(`. The handful that legitimately go straight to
`submit` are listed below with their reason, and anything else fails --
which is the direction a mistake has to fall in.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMMANDS = ROOT / "Sources/MediaIdentifierCore/Web/WebCommands.swift"
# Every front end. A command reachable from either one counts: the headless
# runner legitimately sends some the window does not.
FRONT_ENDS = ["Sources/MediaIdentifierGtk", "Sources/mediafin"]


# Commands the window may hand straight to `submit`, with the reason. The
# gates are the point: anything that sets work in motion has to close them
# at press time, which is what `start(` does.
MAY_SUBMIT_DIRECTLY = {
    # Not work -- and deliberately NOT gated: Stopp has to be pressable
    # exactly while something is running. `submit` also runs these three
    # synchronously on the caller's thread so a Stopp cannot queue behind
    # the thing it is meant to stop.
    "cancelConversions",
    "cancelDownload",
    "cancelScan",
    # Finishes before the press returns, and Übernehmen is not one of the
    # gated buttons. `saveFolders` refreshes itself afterwards, because the
    # answer to a write is what the label waits for.
    "saveSettings",
    # The API key, which lives in its own store beside the settings write.
    "setSecret",
    # Per-row ticks in the proposal list. No work, and gating the list the
    # user is ticking would be its own fault.
    "setAccepted",
    "setAllAccepted",
    # Not work either, so the `isWorking` gate cannot close for it however
    # it is sent: `isWork` returns false and `queuedWork` never rises. It
    # is behind a confirmation dialog, and a second Leeren asks again and
    # then reports "nothing to undo" -- there is nothing a press can land
    # on twice. Kept as a direct send rather than dressed up as `start(`,
    # which would add a refresh that changes nothing and imply a gate that
    # is not there.
    "clearHistory",
}


def strip_comments(text: str) -> str:
    """Drop // lines and /* */ blocks, so a command named only in a comment
    does not count as reachable. That is exactly how a stale comment would
    keep a dead command alive."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return "\n".join(line.split("//")[0] for line in text.splitlines())


def main() -> int:
    if not COMMANDS.exists():
        print(f"FAIL  : {COMMANDS} is missing")
        return 1

    body = COMMANDS.read_text(encoding="utf-8")
    inside = False
    names = []
    for line in body.splitlines():
        if re.match(r"\s*public enum WebCommand\b", line):
            inside = True
            continue
        if inside:
            match = re.match(r"\s*case (.+)", line)
            if not match:
                continue
            # "case a, b, c" on one line is legal Swift, and so is
            # "case setSecret(SecretKey, String)". Splitting on commas
            # naively collects the associated TYPES as command names -- the
            # first version of this did, and reported Bool and String as
            # unreachable commands, which is the kind of nonsense that
            # teaches people to ignore a check. So the payload is dropped
            # first, at the opening bracket.
            rest = match.group(1)
            depth = 0
            bare = []
            for character in rest:
                if character == "(":
                    depth += 1
                elif character == ")":
                    depth = max(0, depth - 1)
                elif depth == 0:
                    bare.append(character)
            for piece in "".join(bare).split(","):
                name = re.match(r"\s*([a-zA-Z][a-zA-Z0-9]*)", piece)
                if name:
                    names.append(name.group(1))
    names = sorted(set(names))
    if not names:
        # A check that finds nothing to check is a check that cannot fail.
        print("FAIL  : no commands found in WebCommands.swift -- this script "
              "has stopped being able to fail, which is worse than a red build")
        return 1

    sources = []
    for folder in FRONT_ENDS:
        path = ROOT / folder
        if not path.exists():
            print(f"FAIL  : front end {folder} is missing")
            return 1
        sources.extend(path.rglob("*.swift"))
    text = strip_comments(
        "\n".join(p.read_text(encoding="utf-8") for p in sources))

    # `submit(.name` or `start(.name`, with optional whitespace. Anchored on
    # the opening parenthesis, so a method of the same name does not count.
    senders = ("submit", "start")
    unreachable = [
        n for n in names
        if not re.search(
            r"\b(?:%s)\(\s*\.%s\b" % ("|".join(senders), re.escape(n)), text)
    ]
    if unreachable:
        print("FAIL  : these engine commands have no sender in any front end:")
        for name in unreachable:
            print(f"        {name}")
        print()
        print("        Nothing the user can press reaches them. The engine")
        print("        accepts them, their handlers are tested, and the")
        print("        feature does not exist. Wire it up, or take the")
        print("        command and its handler out.")
        print()
        print("        If you added a new way to send commands, add its")
        print(f"        name beside {senders} above -- this check only")
        print("        recognises a send it knows the shape of.")
        return 1

    # Second rule: in the WINDOW, work goes through `start(`.
    #
    # AppWindow.swift only, because the gates are its. main.swift sends the
    # demo library's scan straight to the engine on purpose, before gtk_init
    # has run and before any window exists -- there is nothing to gate
    # there, and letting the whole target off would also let a bare
    # `submit(.scanSourceFolder)` back into the window, which is the fault.
    window = ROOT / "Sources/MediaIdentifierGtk/AppWindow.swift"
    if not window.exists():
        print(f"FAIL  : {window} is missing")
        return 1
    window_text = strip_comments(window.read_text(encoding="utf-8"))
    bare = sorted({
        m.group(1)
        for m in re.finditer(r"\bsubmit\(\s*\.([a-zA-Z][a-zA-Z0-9]*)",
                             window_text)
    })
    wrong = [n for n in bare if n not in MAY_SUBMIT_DIRECTLY]
    if wrong:
        print("FAIL  : the window sends these straight to `submit`, which "
              "does not close the gates:")
        for name in wrong:
            print(f"        {name}")
        print()
        print("        The gates live in `refresh()` and a 500 ms timer")
        print("        calls it, so a bare submit leaves Umbenennen,")
        print("        Rückgängig and Leeren live for up to half a second")
        print("        after the press. That window is where the Rückgängig")
        print("        double-click reversed a batch nobody asked about.")
        print("        Send it with `start(` instead, or add it to")
        print("        MAY_SUBMIT_DIRECTLY with the reason in writing.")
        return 1

    print(f"ok    : all {len(names)} engine commands have a sender "
          f"({', '.join(FRONT_ENDS)}), and the window starts its work "
          f"through `start(` ({len(bare)} deliberate direct sends)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
