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
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMMANDS = ROOT / "Sources/MediaIdentifierCore/Web/WebCommands.swift"
# Every front end. A command reachable from either one counts: the headless
# runner legitimately sends some the window does not.
FRONT_ENDS = ["Sources/MediaIdentifierGtk", "Sources/mediafin"]


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

    print(f"ok    : all {len(names)} engine commands have a sender "
          f"({', '.join(FRONT_ENDS)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
