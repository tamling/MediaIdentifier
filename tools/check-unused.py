#!/usr/bin/env python3
"""Finds declarations in Sources that only the tests ever use.

This project's recurring failure is a defence that cannot run: a function
with a careful name, a careful comment and three passing tests, and no caller
anywhere in the program. It has happened with

  * sanitizeRelativePath  - path traversal, three tests, no caller
  * WebSettings.problems() - every settings rule, three test files, no caller
  * RenameLog.flush()      - the coalescing window's whole point, no caller
  * RenameLog.lastWriteFailure - set in a catch, read only in init
  * AppWindow.loadedSettings - a nine-line comment, assigned once, never read

Each one reads exactly like a check that passes. So: every func and var
declared under Sources/ must be mentioned somewhere under Sources/ other
than its own declaration. What only the tests use is either dead or a
defence nobody armed.

Deliberate exceptions go in EXEMPT with the reason, which is the point of
the file: an exception has to be argued for once, in writing.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources")

BASELINE_FILE = os.path.join(ROOT, "tools", "unused-baseline.txt")


def baseline():
    """Names already in this state when the check was written.

    A debt list, not an exemption list: the script fails on anything not in
    it, which is the point — the fault this catches is a NEW defence with no
    caller.
    """
    names = set()
    if not os.path.exists(BASELINE_FILE):
        return names
    with open(BASELINE_FILE, encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if line:
                names.add(line)
    return names


EXEMPT = {
    # Deliberately not read by the window: pressing Undo with an empty
    # journal says "Es gab nichts rückgängig zu machen", which is a better
    # answer than a greyed-out button. Written down at the property.
    "canUndo",
    # The engine's own vocabulary, kept whole so a caller can ask any of it:
    # these are read by the GTK target through a protocol or a switch the
    # grep below cannot see.
    "isValid",
}

DECL = re.compile(
    r"^\s*(?:@\w+\s+)*(?:public |internal |private |fileprivate |static |final |class |override |mutating |@discardableResult )*"
    r"(func|var|let)\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def declarations():
    found = {}
    for base, _, names in os.walk(SOURCES):
        for name in names:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(base, name)
            with open(path, encoding="utf-8") as handle:
                for number, line in enumerate(handle, 1):
                    match = DECL.match(line)
                    if not match:
                        continue
                    identifier = match.group(2)
                    if identifier.endswith("ForTesting"):
                        continue
                    if identifier.startswith("_"):
                        continue
                    if identifier in EXEMPT:
                        continue
                    # A local inside a function body is not a declaration
                    # this cares about; indentation past 8 spaces is the
                    # cheap test for that.
                    if len(line) - len(line.lstrip(" ")) > 8:
                        continue
                    kind = "func" if match.group(1) == "func" else "property"
                    found.setdefault(identifier, []).append(
                        (path, number, kind))
    return found


def mentions():
    text = []
    for base, _, names in os.walk(SOURCES):
        for name in names:
            if name.endswith(".swift"):
                with open(os.path.join(base, name), encoding="utf-8") as handle:
                    text.append(handle.read())
    return "\n".join(text)


def main():
    body = mentions()
    known = baseline()
    unused = []
    fixed = []
    for identifier, places in sorted(declarations().items()):
        # One mention is the declaration itself. Two or more means somebody
        # else refers to it -- or it is assigned as well as declared, which
        # is why the message says "mentions" rather than "callers".
        name = re.escape(identifier)
        funcs = [p for p in places if p[2] == "func"]
        properties = [p for p in places if p[2] == "property"]
        if funcs and properties:
            # A name declared in two shapes: a function and a property of
            # the same name. The bare-name count cannot tell their mentions
            # apart, so one of them is satisfied by the other's call sites
            # and by its own body -- which is how the no-argument
            # `estimatedSizePercent` sat here dead, with 5 mentions against
            # 2 declarations and a cheerful "ok". The same blind spot
            # check-reachable.py had, where `.clearHistory` was satisfied by
            # the window's own method name.
            #
            # So each shape is counted by the shape of its own mentions: a
            # call is `name(`, a property read is `name` NOT followed by
            # `(`. A property's own body calling the function overload is
            # then a function mention, which is what it is.
            calls = len(re.findall(r"\b" + name + r"\s*\(", body))
            reads = len(re.findall(r"\b" + name + r"\b(?!\s*\()", body))
            shapes = [("func", calls - len(funcs), funcs),
                      ("property", reads - len(properties), properties)]
            for _, left, where in shapes:
                if left <= 0:
                    if identifier not in known:
                        unused.append((identifier, where))
                    break
            else:
                if identifier in known:
                    fixed.append(identifier)
            continue
        uses = len(re.findall(r"\b" + name + r"\b", body))
        if uses - len(places) <= 0:
            if identifier not in known:
                unused.append((identifier, places))
        elif identifier in known:
            fixed.append(identifier)
    if fixed:
        print("note  : these now have a caller and can come out of "
              "tools/unused-baseline.txt:")
        for identifier in sorted(fixed):
            print(f"        {identifier}")
    if not unused:
        print(f"ok    : no new declaration is used only by tests "
              f"({len(known)} known, see tools/unused-baseline.txt)")
        return 0
    print("FAIL  : these are newly declared in the program and used only "
          "by tests:")
    for identifier, places in unused:
        where = ", ".join(f"{p[len(ROOT) + 1:]}:{n} ({k})"
                          for p, n, k in places)
        print(f"        {identifier}  ({where})")
    print()
    print("        Each one is either dead, or a defence with no caller --")
    print("        which reads exactly like a check that passes. Give it a")
    print("        caller, or delete it. Adding it to")
    print("        tools/unused-baseline.txt needs a reason in writing.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
