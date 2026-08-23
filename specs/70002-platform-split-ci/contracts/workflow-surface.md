# Contract: Workflow surface

This feature has no API. Its contract is the surface a repository owner and a contributor interact
with: which workflows exist, what each requires, what it does when it cannot run, and the checker
that guards the arrangement.

## Workflows

Each file is one tier on one platform. Triggers are copied verbatim from `ci.yml` and are not part of
what this change decides (FR-007).

| Workflow | Platform | Runner labels | Requires | Triggers |
|---|---|---|---|---|
| `ci-conformance-linux.yml` | Linux | `nix-enabled-runners` | dev shell | push(master), pull_request, dispatch |
| `ci-conformance-macos.yml` | macOS | `[self-hosted, macOS, ARM64, cardano-wallet]` | dev shell | push(master), pull_request, dispatch |
| `ci-verification-linux.yml` | Linux | `nix-enabled-runners` | built derivations; local cluster capable | push(master), pull_request, dispatch |
| `ci-verification-macos.yml` | macOS | as above | built derivations; local cluster capable | push(master), pull_request, dispatch |
| `ci-publication-linux.yml` | Linux | `nix-enabled-runners` | `secrets.ATTIC_TOKEN` for `attic-cache` | push(master), pull_request, dispatch |
| `ci-publication-macos.yml` | macOS | as above | — | push(master), pull_request, dispatch |

**Guarantees.**

1. A workflow whose runner labels a repository can serve reaches a conclusion, regardless of any
   other workflow's fate.
2. Disabling a workflow through Actions settings affects no other workflow.
3. With no repository variables set, the commands executed are byte-identical to `d3d170d02`.
4. No workflow names labels for more than one platform.

**Obligations on a contributor adding a job.** Place it in the workflow matching its platform and
tier. Do not add a `needs` edge to a job in another workflow — it is not expressible, and the checker
fails if the platform boundary is crossed. A job requiring credentials belongs in publication.

## Repository variables

Read by `ci-verification-linux.yml`. Unset means today's behaviour.

| Variable | Default | Effect |
|---|---|---|
| `INTEGRATION_JOBS` | `6` | `-j` for the integration suite. Lower on machines with few cores: the suite runs one cluster and races against block production, and those races widen under CPU contention. |
| `TESTS_RETRY_FAILED` | `1` | Retry failed examples once. `0` to observe the raw flake rate. |

Both values MUST be echoed to the run log before the suite starts (FR-011).

## `scripts/ci/check-workflow-platforms.sh`

```
check-workflow-platforms.sh            # assert invariants; non-zero exit on breach
check-workflow-platforms.sh --print    # emit the job matrix on stdout
```

**Asserts.**

1. Every workflow under `.github/workflows/` names runner labels for at most one platform.
2. No `needs` edge crosses a platform boundary.

**Prints**, one record per job, in a stable order so two revisions can be diffed:

```
<workflow> <job-id> <platform> <runner-labels> <needs...> <commands...>
```

**Does not** compare against a committed baseline (FR-013). Equivalence across this change is shown
by running `--print` at `d3d170d02` and at the branch tip and diffing; a stored snapshot would have
to be updated whenever a job is legitimately added, which makes it a chore and eventually a deleted
check.

**Exit codes**: `0` invariants hold; `1` a violation, naming the workflow, job and edge; `2` a
workflow file could not be parsed.

## Out of contract

- Trigger policy, including whether macOS runs at pull-request time (#5330)
- Failure alerting (#5330)
- `macos-unit-tests.yml`, `macos-integration.yml`, `windows.yml`, `windows-e2e.yml` — audited into
  documentation, unchanged
- Branch-protection configuration, which lives in repository settings and can only be identified
  here, not changed (FR-006)
