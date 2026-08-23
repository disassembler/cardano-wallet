#!/usr/bin/env bash

# Derive the job matrix from the workflow files and assert the properties that
# keep a workflow runnable by a repository that cannot serve every platform.
#
#   check-workflow-platforms.sh           assert; non-zero exit on a violation
#   check-workflow-platforms.sh --print    emit the job matrix on stdout
#
# Asserted:
#
#   1. A workflow names runner labels for at most one platform. A workflow whose
#      jobs span platforms cannot conclude on a repository that serves only one
#      of them: the jobs it cannot run stay queued forever.
#   2. No `needs` edge crosses a platform boundary.
#
# The printed form is one record per *check* rather than per job definition:
# a job carrying `strategy.matrix.include` produces one check per entry, and
# comparing definitions would be blind to an entry disappearing.
#
# Commands are emitted in full, with whitespace collapsed but nothing elided.
# Truncating them would let a change past the cut-off pass as equivalent, which
# is the exact false verdict this output exists to rule out.
#
# There is deliberately no committed baseline to compare against. Equivalence
# across a change is shown by running --print at two revisions and diffing;
# a stored snapshot would need updating whenever a job is legitimately added,
# which turns it into a chore and then into a deleted check.

set -euo pipefail

WORKFLOW_DIR="${WORKFLOW_DIR:-.github/workflows}"

usage() {
    cat >&2 <<'EOF'
usage: check-workflow-platforms.sh [--print]

  (no arguments)  assert the invariants; exit 1 on violation, 2 on parse failure
  --print         emit one record per check: workflow|job|platform|labels|needs|commands
EOF
}

mode="assert"
case "${1:-}" in
    --print) mode="print" ;;
    "") ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [ ! -d "$WORKFLOW_DIR" ]; then
    echo "error: no such directory: $WORKFLOW_DIR" >&2
    exit 2
fi

python3 - "$mode" "$WORKFLOW_DIR" <<'PYTHON'
import sys
import glob
import os

try:
    import yaml
except ImportError:
    print("error: PyYAML is required", file=sys.stderr)
    raise SystemExit(2)

mode, workflow_dir = sys.argv[1], sys.argv[2]

# Workflows that require more than one platform by construction, and are
# therefore exempt from both assertions.
#
# These build an artifact on Linux and then execute it on the target platform,
# so the dependency cannot be removed — only the whole workflow can be declined.
# A repository unable to serve the target platform gets no conclusion from them,
# which is the same defect this feature removes from ci.yml, recorded here so it
# is visible rather than silently tolerated.
#
# Adding a workflow to this set is a decision, not a fix. Nothing else may
# acquire cross-platform coupling without failing.
KNOWN_CROSS_PLATFORM = {
    "release.yml",         # create-release needs e2e-windows
    "verify-release.yml",  # verifies artifacts for all three platforms
    "windows.yml",         # windows jobs consume Linux cross-builds
    "windows-e2e.yml",     # e2e-tests needs build-e2e
}


def platform_of(runs_on):
    """Classify a runs-on value. 'dynamic' when an expression decides it."""
    if runs_on is None:
        return "none"
    labels = [runs_on] if isinstance(runs_on, str) else list(runs_on)
    joined = " ".join(str(x) for x in labels)
    if "${{" in joined:
        return "dynamic"
    lowered = joined.lower()
    if "macos" in lowered:
        return "macos"
    if "windows" in lowered:
        return "windows"
    if "nix-enabled-runners" in lowered or "ubuntu" in lowered or "linux" in lowered:
        return "linux"
    return "other"


def commands_of(job):
    out = []
    for step in job.get("steps") or []:
        run = step.get("run")
        if run:
            out.append(" ".join(run.split()))
        elif step.get("uses"):
            out.append("uses:" + str(step["uses"]))
    return out


def matrix_entries(job):
    """One entry per resulting check. A job without an include matrix is one."""
    strategy = job.get("strategy") or {}
    matrix = strategy.get("matrix") or {}
    include = matrix.get("include")
    if not include:
        return [(None, None)]
    entries = []
    for item in include:
        name = item.get("name")
        command = item.get("command")
        entries.append((name, " ".join(str(command).split()) if command else None))
    return entries


records = []
platforms_by_workflow = {}
platform_by_job = {}
needs_by_job = {}
parse_failed = False

for path in sorted(glob.glob(os.path.join(workflow_dir, "*.yml"))
                   + glob.glob(os.path.join(workflow_dir, "*.yaml"))):
    try:
        doc = yaml.safe_load(open(path)) or {}
    except yaml.YAMLError as exc:
        print("error: cannot parse {}: {}".format(path, exc), file=sys.stderr)
        parse_failed = True
        continue

    workflow = os.path.basename(path)
    for job_id, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        platform = platform_of(job.get("runs-on"))
        needs = job.get("needs") or []
        needs = [needs] if isinstance(needs, str) else list(needs)

        platform_by_job[(workflow, job_id)] = platform
        needs_by_job[(workflow, job_id)] = needs
        platforms_by_workflow.setdefault(workflow, set()).add(platform)

        labels = job.get("runs-on")
        labels = labels if isinstance(labels, str) else ",".join(map(str, labels or []))
        base_commands = commands_of(job)

        for entry_name, entry_command in matrix_entries(job):
            check = job_id if entry_name is None else "{} / {}".format(job_id, entry_name)
            commands = base_commands if entry_command is None else [entry_command]
            records.append((workflow, check, platform, labels,
                            ";".join(sorted(needs)), " && ".join(commands)))

if parse_failed:
    raise SystemExit(2)

if mode == "print":
    for row in sorted(records):
        print("|".join(row))
    raise SystemExit(0)

violations = []

# 1. one platform per workflow, ignoring jobs whose platform an expression decides
for workflow, platforms in sorted(platforms_by_workflow.items()):
    if workflow in KNOWN_CROSS_PLATFORM:
        continue
    concrete = {p for p in platforms if p not in ("dynamic", "none")}
    if len(concrete) > 1:
        violations.append(
            "{}: jobs span platforms {} — a repository serving only one of them "
            "never reaches a conclusion".format(workflow, sorted(concrete)))

# 2. no needs edge across a platform boundary
for (workflow, job_id), needs in sorted(needs_by_job.items()):
    if workflow in KNOWN_CROSS_PLATFORM:
        continue
    here = platform_by_job[(workflow, job_id)]
    for dep in needs:
        there = platform_by_job.get((workflow, dep))
        if there is None:
            continue
        if here in ("dynamic", "none") or there in ("dynamic", "none"):
            continue
        if here != there:
            violations.append(
                "{}: job '{}' ({}) needs '{}' ({}) — dependency crosses a "
                "platform boundary".format(workflow, job_id, here, dep, there))

if violations:
    print("check-workflow-platforms: {} violation(s)".format(len(violations)),
          file=sys.stderr)
    for v in violations:
        print("  " + v, file=sys.stderr)
    raise SystemExit(1)

print("check-workflow-platforms: {} checks across {} workflows, invariants hold".format(
    len(records), len(platforms_by_workflow)))
PYTHON
