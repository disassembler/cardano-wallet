# Research: Platform and tier split of the CI workflow

**Measured at**: `d3d170d02`, 2026-08-13. All job, runner and dependency facts below come from
parsing `.github/workflows/*.yml` at that revision.

## Current-state inventory

`ci.yml` — 21 jobs, two platforms, five independent gates:

| Gate | Platform | Consumers |
|---|---|---|
| `build-gate` | Linux | `nix-check`, `unit-tests`, `integration`, `local-cluster`, `boot-syncs` |
| `build-gate-quality` | Linux | `quality-checks`, `attic-cache` |
| `build-gate-artifacts` | Linux | `artifacts-package`, `artifacts-wallet-key-export`, `artifacts-shell`, `docker`, `attic-cache` |
| `build-gate-windows` | Linux | `attic-cache` |
| `build-gate-mac` | macOS | `mac-nix-check`, `mac-local-cluster`, `mac-package-intel`, `mac-package-silicon` |

`docker-boot-sync` depends on `docker` rather than on a gate. No `needs` edge crosses the
Linux/macOS boundary; the platforms are already independent in every respect except sharing a run
conclusion.

The other four workflows, for the audit required by FR-009:

| Workflow | Triggers | Jobs | Runner labels |
|---|---|---|---|
| `macos-unit-tests.yml` | push(master), dispatch | 3 | macOS self-hosted |
| `macos-integration.yml` | push(master), dispatch | 2 | macOS self-hosted |
| `windows.yml` | push(master), dispatch | 6 | `nix-enabled-runners`, `windows-2025-vs2026` |
| `windows-e2e.yml` | dispatch only | 2 | `nix-enabled-runners`, `windows-2025-vs2026` |

`windows.yml` and `windows-e2e.yml` carry the same cross-platform coupling this feature removes from
`ci.yml`. `windows-2025-vs2026` is not a GitHub-hosted image — `actionlint` does not recognise it —
so it is an organisation-specific larger runner that no fork can serve without equivalent hardware.

## Decisions

| Decision | Rationale | Alternative rejected |
|---|---|---|
| Split by (tier, platform), one workflow per populated pair. | Platform decides whether a repository *can* run a job; tier decides whether it *wants* to. Both must be separable, and GitHub disables workflows rather than jobs, so the file boundary is the only lever. | Splitting by platform alone leaves `attic-cache` — which needs a secret forks cannot hold — welded to the tests they do want. |
| No nix check depends on a build gate, on either platform. `nix-check` and `mac-nix-check` both lose their gate edge and sit in conformance. | Their steps are evaluation-only. The edge makes a version check wait on the heaviest job on its platform, and carrying it would pull the verification gate into the conformance tier, removing the tier's reason to exist. On macOS it additionally suppresses the flake-evaluation diagnostic behind the build failure it exists to report. | Moving them to verification preserves the edge but leaves conformance with no nix check at all. Applying the rule to `nix-check` alone was the original error: `c90183ec2` reversed both edges, so fixing one job leaves the other inverted. |
| Every `build-gate*` job opens with its platform's nix check as a step. | `c90183ec2` consolidated twenty-two workflows into one and re-pointed each edge at the new gates, reversing an arrow that previously ran the other way: `nix-check.yml` had no `needs`, and in `macos-nix-check.yml` it was `attic-cache` that declared `needs: check-nix`. Restoring the precondition makes a runner without nix fail at a named step rather than inside a multi-derivation build. Linux gates take `nix --version`, macOS gates take `nix --version` and `nix flake info` — each platform's historical check, no invented commands. | A `needs` edge cannot express this after the split, since the check and the gates land in different workflows and workflows cannot share jobs. `workflow_run` fires only on the default branch, so it would not gate pull requests at all. |
| `attic-cache` joins publication, keeps the two gate edges that move with it, and inlines only the third gate's build as a step. | `build-gate-artifacts` and `build-gate-windows` land in the same workflow, so those edges survive unchanged; only `build-gate-quality` is left behind in conformance, and workflows cannot share jobs. On a persistent store the one repeated `nix build` is a no-op. | A `workflow_run` trigger chaining it after the others fires only on the default branch and adds a failure mode that is harder to reason about than a repeated no-op build. |
| Gates stay jobs within their tier workflow, rather than being inlined as steps into every dependent. | A gate job runs its build once and fans out to its dependents through `needs`; inlining would make each dependent repeat the build, which is a no-op only on a warm store and a serial rebuild otherwise. `build-gate-mac` is therefore duplicated across the two macOS workflows that have dependents, not across every macOS job. | Inlining everywhere reduces the job count and the number of check names to migrate, but pays for it with repeated builds and loses the parallel fan-out the gate exists to provide. |
| `nix-check` is dropped rather than moved. | Once `build-gate-quality` opens with `nix --version`, the job is a duplicate of that step on the same runner label at the same time, and pays a `fetch-depth: 0` full-history clone to run one command. It could only ever fail where the gate also fails. | Keeping it preserves an existing status-check name, which matters if branch protection references it. This is the change's only job deletion and the one most likely to need reverting on maintainer instruction — see FR-006. |
| Capability declarations are repository variables read from job-level `if:`, one per runner kind. | `vars` is available to a job-level `if:` where `secrets` is not, so no mapping job is needed. A declaration turns an indefinite queue into a reported skip, which satisfies branch protection where a job that never reports leaves a required check pending forever. | Disabling the workflow achieves the same suppression but leaves no trace on any pull request, so a repository that later acquires the hardware has nothing reminding it, and a workflow disabled as a stopgap stays disabled indefinitely. |
| A capability declaration must not be expressible as a gate job. | Such a job would have to run on some platform, and the guarded jobs depending on it would create exactly the cross-platform `needs` edge FR-015 forbids and the checker rejects. | Per-job `if:` is more repetition, but it is the only shape that does not reintroduce the coupling this feature removes. |
| One workflow requires neither nix nor a self-hosted runner, and carries no guard. | It is the floor: every repository holding the source reports on every pull request whatever hardware it owns, so a declaration can never empty a repository's coverage. | Leaving the nix tiers as the only coverage means `HAS_NIX_RUNNER=false` yields a green pull request attesting that nothing ran, which is worse than a red one. |
| Membership in the hosted tier needs both halves of the rule: no nix command, **and** a subject that is the repository rather than the runner fleet. | The mechanical half alone admits `check-docker-boot-sync-cleanup.sh`, which only greps but guards teardown that matters because self-hosted runners persist between jobs — a failure a repository without such runners cannot encounter. Placing it on the floor would tell contributors something true and useless. | A purely mechanical rule is easier to apply and needs no judgement, but it sorts by implementation detail rather than by who the check serves, which is the axis the whole tier split is built on. |
| The hosted checks duplicate their nix-tier copies rather than moving out of `quality-checks`. | Duplication keeps the change additive, renames no existing status check, and leaves the hosted copies reporting when the self-hosted fleet is saturated or unavailable. | Moving them is tidier and halves the run count, but changes five check names and so drags the branch-protection migration into a change that otherwise needs none. |
| Variables `INTEGRATION_JOBS` and `TESTS_RETRY_FAILED`, defaulting to `6` and `1`. | Those are today's hardcoded values, so an unset variable is a no-op for upstream, while a fork tunes without editing a tracked file. Directly serves the constraint recorded in #5114. | Lowering the defaults would change upstream behaviour to suit constrained hardware, which is not ours to decide. |
| The checker asserts an invariant, not a baseline. | A frozen list of job names must be updated whenever a job is legitimately added, which turns it into a chore and then into a deleted check. The invariant — no `needs` edge crossing a platform — needs no maintenance and cannot be satisfied vacuously. | A committed baseline detects any change, including intended ones, and would fail on the next unrelated CI edit. |
| Triggers are copied verbatim into each new workflow. | FR-007. Whether macOS runs at pull-request time is #5330's decision, and upstream has one macOS runner, so wiring it to every PR would serialise the repository behind one machine. | Adding `pull_request` to the macOS workflows would appear to close #5330 while actually pre-empting the decision it asks for. |

## What this does not do

Stated here so the plan, the tasks and the eventual pull request all say the same thing:

- It does not change when any workflow runs. #5330 asks for a decision between failure alerting, a
  lightweight PR check and full gating, plus alerting within an hour. This change makes those
  options implementable — a macOS tier can be wired to `pull_request` without dragging sixteen Linux
  jobs — but takes none of them.
- It does not close #5146. That issue's first criterion is zero `buildkite` matches under `docs/`;
  there are 35, and two of the three files are decision records (`2023-01-27-continuous-integration.md`,
  `2026-02-10-migrate-ci-to-github-actions.md`) where the reference is historically correct and
  should not be scrubbed. This change advances the issue's contributor-guide criterion only.
- It does not touch `macos-unit-tests.yml`, `macos-integration.yml`, `windows.yml` or
  `windows-e2e.yml`. They are audited into documentation.
- It does not change any product code, dependency pin or test.

## Risks

- **Branch protection.** Check names change. Nothing in the repository records which are required, so
  the set must be obtained from the maintainers or from repository settings, and named in the pull
  request. A split that silently drops a required check is worse than no split.
- **`attic-cache` on forks.** Its `if:` admits same-repository pull requests, so a fork running its
  own pull requests reaches it and fails on the missing `ATTIC_TOKEN`. Moving it to the publication
  tier lets a fork disable it wholesale, which is the fix available here; tightening the guard itself
  is a one-line change that could ride along or be left to the maintainers.
- **Cold runners.** Each tier workflow runs its own gate step. The assumption of a persistent nix
  store is explicit in the spec; on ephemeral runners the split would multiply build cost.
- **Reviewer fatigue.** Six new files touching every job in the repository's main workflow. The
  mitigation is that the diff is mechanical and the equivalence is demonstrated by a script the
  reviewer can run, not by prose.
