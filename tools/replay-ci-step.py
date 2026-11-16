#!/usr/bin/env python3
"""Runs a workflow job's `run:` scripts here, the way Actions would.

The fault this exists for: `check-workflows.py` reports "shell parses" for a
step whose shell is perfectly valid and still wrong. A stray `\\"` at the end
of an `echo` turned the next line into part of the string, so an assignment
never happened and `set -u` killed the step on the first use of the variable
-- in CI, on a push, after every local check had passed. The step's own
output was correct; only the harness around it was broken.

`bash -n` cannot see that, and neither can reading it. What sees it is
running it. This container has GTK, Xvfb, FFmpeg and the Swift toolchain, so
the GTK job's steps can run here against a release build, under the same
shell flags Actions uses: `bash --noprofile --norc -e -o pipefail`.

Usage:
    tools/replay-ci-step.py gtk                 # every run: step in the job
    tools/replay-ci-step.py gtk 6               # one step, by its number
    tools/replay-ci-step.py gtk 6 --list        # just list them

Steps that install packages are skipped: the tools are already here, and
apt in this container is not the point.
"""
import os
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/build.yml"
# Package installation and artifact uploads are Actions' business, not the
# shell's. Matched against the step name.
SKIP = ("Install ", "Upload ", "Emit ")


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    job_name = sys.argv[1]
    wanted = None
    for argument in sys.argv[2:]:
        if argument.isdigit():
            wanted = int(argument)
    listing = "--list" in sys.argv

    jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    if job_name not in jobs:
        print(f"FAIL  : no job {job_name!r}; have {', '.join(jobs)}")
        return 64

    steps = jobs[job_name].get("steps", [])
    scratch = pathlib.Path(
        os.environ.get("REPLAY_DIR", "/tmp/ci-replay")) / job_name
    scratch.mkdir(parents=True, exist_ok=True)

    failures = []
    for number, step in enumerate(steps, 1):
        script = step.get("run")
        name = step.get("name", "(unnamed)")
        if script is None:
            continue
        if wanted is not None and number != wanted:
            continue
        if any(name.startswith(prefix) for prefix in SKIP):
            print(f"skip  : {number:2d}. {name}")
            continue
        if listing:
            print(f"      : {number:2d}. {name} "
                  f"({len(script.splitlines())} lines)")
            continue

        path = scratch / f"step-{number:02d}.sh"
        path.write_text(script, encoding="utf-8")
        print(f"\n===== {number:2d}. {name} =====", flush=True)
        # The same flags Actions gives a `run:` block, and the repository as
        # the working directory, because every path in these scripts is
        # relative to it.
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail",
             str(path)],
            cwd=ROOT)
        if result.returncode != 0:
            print(f"FAIL  : step {number} ({name}) exited "
                  f"{result.returncode}")
            failures.append((number, name, result.returncode))

    if listing:
        return 0
    if failures:
        print("\nFAIL  : these steps did not pass here:")
        for number, name, code in failures:
            print(f"        {number:2d}. {name} (exit {code})")
        return 1
    print("\nok    : every replayed step passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
