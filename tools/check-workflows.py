#!/usr/bin/env python3
"""Refuses a workflow file that GitHub Actions would refuse.

Why this exists: `yaml.safe_load` accepts a mapping with the same key twice
and keeps the last one. GitHub Actions rejects it outright -- "'with' is
already defined" -- so a file can load perfectly here and still be unusable
there. That is exactly what happened: a bad edit put two `with:` blocks on one
step, the load said it was fine, and the next release could not start at all.

So this walks the YAML with a loader that treats a duplicate key as an error,
which is the one thing the permissive load cannot tell you.
"""

import os
import subprocess
import sys
import tempfile

import yaml


class StrictLoader(yaml.SafeLoader):
    """SafeLoader, except that a repeated key in one mapping is a failure."""


def no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            mark = key_node.start_mark
            raise yaml.constructor.ConstructorError(
                None, None,
                f"'{key}' is already defined "
                f"(line {mark.line + 1}, column {mark.column + 1})",
                node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)


def shell_parses(path, document):
    """Runs `bash -n` over every `run:` script in the file.

    A workflow whose shell does not parse fails in exactly the same way as
    one whose YAML does not: the job dies before it does anything, and the
    only clue is in a log nobody reads until the release is late. It is
    cheap to rule out here, where the error names the step.

    The reason it is worth having: these scripts are written inside a YAML
    block scalar, so every heredoc terminator sits at an indentation that
    looks wrong and has to be right, and `set -e` interacts with `&&` in a
    way that is easy to get backwards. One of those cost a red build.
    """
    ok = True
    for job_name, job in (document.get("jobs") or {}).items():
        for index, step in enumerate(job.get("steps") or []):
            script = step.get("run")
            if not script:
                continue
            name = step.get("name") or f"step {index + 1}"
            with tempfile.NamedTemporaryFile("w", suffix=".sh",
                                             delete=False) as handle:
                handle.write(script)
                temporary = handle.name
            try:
                result = subprocess.run(["bash", "-n", temporary],
                                        capture_output=True, text=True)
            finally:
                os.unlink(temporary)
            if result.returncode != 0:
                detail = result.stderr.strip().replace(temporary, name)
                print(f"FAIL  : {path}: {job_name} / {name}: {detail}")
                ok = False
    return ok


def check(path):
    with open(path, encoding="utf-8") as handle:
        try:
            document = yaml.load(handle, Loader=StrictLoader)
        except yaml.YAMLError as error:
            print(f"FAIL  : {path}: {error}")
            return False
    if not isinstance(document, dict) or "jobs" not in document:
        print(f"FAIL  : {path}: no jobs")
        return False
    if not shell_parses(path, document):
        return False
    print(f"ok    : {path}: {len(document['jobs'])} job(s), shell parses")
    return True


if __name__ == "__main__":
    paths = sys.argv[1:]
    if not paths:
        print("usage: check-workflows.py FILE...", file=sys.stderr)
        sys.exit(64)
    sys.exit(0 if all(check(p) for p in paths) else 1)
