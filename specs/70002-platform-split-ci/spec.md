# Feature Specification: A Fork With One Platform's Runners Cannot Get A CI Verdict

**Feature Branch**: `70002-platform-split-ci`
**Created**: 2026-08-13
**Status**: Draft
**Input**: `ci.yml` spans Linux and macOS in a single workflow run. A fork that has runners for only
one of them cannot reach a conclusion: the jobs it cannot serve stay queued indefinitely, so the run
never completes and every pull request is left without a verdict. The two platform sets have no
dependencies between them, so nothing but their shared workflow file couples them.

## Background

`ci.yml` defines 21 jobs. Sixteen run on `nix-enabled-runners`; five run on
`[self-hosted, macOS, ARM64, cardano-wallet]`. Windows is not in this workflow at all —
`build-gate-windows` cross-compiles on Linux, and the Windows suites live in `windows.yml` and
`windows-e2e.yml`.

Every runner label in the file is self-hosted and organisation-specific. A fork inherits the
workflows on day one, but not the machines they name.

The five macOS jobs — `build-gate-mac`, `mac-nix-check`, `mac-local-cluster`, `mac-package-intel`,
`mac-package-silicon` — form a closed set: no Linux job declares `needs` on any of them, and none of
them declares `needs` on a Linux job. They are independent today in every respect except that they
share a workflow file, and therefore a run conclusion.

The consequence for a fork with Linux runners is total rather than partial. Sixteen jobs run and
pass; five sit queued; the run never concludes; branch protection has nothing to gate on, and the
pull request page shows work in progress forever.

The wider picture, measured at `d3d170d02`:

| Workflow | Triggers | Jobs | Runner labels |
|---|---|---|---|
| `ci.yml` | push(master), pull_request, dispatch | 21 | `nix-enabled-runners`, macOS self-hosted |
| `macos-unit-tests.yml` | push(master), dispatch | 3 | macOS self-hosted |
| `macos-integration.yml` | push(master), dispatch | 2 | macOS self-hosted |
| `windows.yml` | push(master), dispatch | 6 | `nix-enabled-runners`, `windows-2025-vs2026` |
| `windows-e2e.yml` | dispatch only | 2 | `nix-enabled-runners`, `windows-2025-vs2026` |

`ci.yml` is not the only workflow with jobs split across platforms: `windows.yml` and
`windows-e2e.yml` mix Linux and Windows runners the same way. Every label is self-hosted or
organisation-specific — `windows-2025-vs2026` is not a GitHub-hosted image — so no fork can serve
them without provisioning equivalent hardware.

## Clarifications

### Session 2026-08-13

- Q: Where does this feature stop — structural split only, or does it also change triggers or add
  alerting? → A: Structural split, plus contributor documentation of what each workflow requires and
  how to run it on modest hardware. Triggers and alerting are not changed. The split unblocks #5330's
  options but does not claim to close it: that issue asks for a maintainer decision between three
  options and for failure alerting, and upstream has a single macOS runner, so wiring macOS to every
  pull request would serialise the repository behind one machine — a policy call that belongs in its
  own change.
- Q: Which workflows are in scope? → A: `ci.yml` is restructured. The four push-only workflows
  (`macos-unit-tests.yml`, `macos-integration.yml`, `windows.yml`, `windows-e2e.yml`) are audited and
  documented but not changed, so that #5330 and #5146 receive findings rather than competing code.
- Q: For constrained hardware, do we document only or also make the knobs configurable? → A: Both.
  Integration concurrency and failed-example retry become repository variables defaulting to today's
  values, so upstream behaviour is unchanged when nothing is set and a fork tunes without editing a
  workflow file.
- Q: How is "the same jobs still run the same commands" demonstrated? → A: A checked-in script
  extracts the job matrix from the workflow files, so the claim is evidence a reviewer can re-run
  rather than a diff they must trust. It also asserts the structural invariant permanently, which
  is what keeps the split from silently regressing later.
- Q: How far does the demarcation go — platform only, or also by area of concern? → A: Both, as a
  tier × platform matrix. Three tiers by capability — conformance, verification, publication — each
  with a per-platform workflow, so every workflow is single-platform and can conclude on whatever
  runners a repository has. A contributor disables a tier or a platform without disabling the rest.
- Q: What distinguishes one tier from another? → A: Who benefits from the output. Conformance
  benefits every collaborator; verification benefits whoever changes the code and whoever pins its
  outputs; publication benefits only the canonical repository's audience. A build feeding only a
  publication job is publication regardless of what it compiles.
- Q: What becomes of `ci.yml`? → A: It is retained as the conformance workflow for Linux — the
  baseline that must always pass. Keeping the name preserves an existing required-status-check
  identity, and conformance is the tier that is relevant to every repository holding the source.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A Fork With Runners For One Platform (Priority: P1)

A community maintainer forks the repository, registers a Linux runner labelled
`nix-enabled-runners`, and opens a pull request. Sixteen jobs run to completion. Five macOS jobs
remain queued because no macOS runner exists and none can be provisioned. The run has no conclusion,
so the pull request cannot be gated, and the maintainer cannot tell a passing branch from a failing
one without reading individual job results by hand.

**Why this priority**: Without this, a fork has no usable CI at all. Every other improvement is
secondary to being able to tell whether a change is good.

**Independent Test**: In a repository with runners for one platform only, open a pull request and
observe whether any workflow reaches a conclusion.

**Acceptance Scenarios**:

1. **Given** a fork with Linux runners and no macOS runners, **When** a pull request is opened,
   **Then** the Linux workflow reaches a success or failure conclusion on its own.
2. **Given** the same fork, **When** the macOS workflow cannot be served, **Then** its inability to
   run does not prevent the Linux workflow from concluding.
3. **Given** the upstream repository, which has runners for both, **When** a pull request is opened,
   **Then** the same jobs run as before this change, with the same results.

---

### User Story 2 - Knowing Which Checks A Fork Can Expect To Run (Priority: P2)

A maintainer evaluating whether to contribute needs to know, before provisioning anything, which
checks their infrastructure can serve and which they must do without.

**Why this priority**: Answerable only by reading every workflow and cross-referencing runner labels.
The information exists but is not stated anywhere.

**Independent Test**: A new contributor can determine the runner requirements of each workflow from
documentation, without reading the workflow files.

**Acceptance Scenarios**:

1. **Given** the contributor documentation, **When** a maintainer looks for CI requirements,
   **Then** each workflow's required runner labels and platform are stated.

---

### User Story 3 - Rerunning One Platform (Priority: P3)

A maintainer whose macOS runner failed transiently wants to rerun the macOS jobs without repeating
sixteen Linux jobs, including a build gate measured in hours.

**Why this priority**: A cost and turnaround improvement that also applies upstream, where a flaky
platform currently drags the whole run with it.

**Acceptance Scenarios**:

1. **Given** a completed run, **When** one platform's workflow is rerun, **Then** the other
   platform's jobs are not re-executed.

### Edge Cases

- **A fork with neither platform's runners.** Both workflows queue and neither concludes. Out of
  scope: nothing can run work without machines. The documentation of User Story 2 is what serves
  this reader.
- **A fork that adds macOS later.** Registering a runner with the documented labels must be
  sufficient; no workflow edit should be required.
- **Required status checks.** Splitting one workflow into two changes the set of check names a
  branch-protection rule can reference. Existing rules naming the old run must be updated, and the
  change is not complete until that is stated.
- **Jobs added later.** Nothing prevents a future job from being added to the wrong workflow or from
  declaring a dependency across the platform boundary, which would silently restore the coupling.
- **Build gates are shared within a platform but not across workflows.** Today three Linux tiers draw
  on three separate gates and the five macOS jobs share one. Workflows cannot share a job, so each
  tier workflow needs its own gate step. On a runner with a persistent nix store this is a no-op —
  the derivations are already realised — but on an ephemeral runner it would mean rebuilding per
  tier. The split therefore assumes persistent runners, which is what both this repository and any
  fork following its runner documentation use.
- **A tier with no jobs on a platform.** Not every tier needs a workflow for every platform; the
  matrix is populated where jobs exist rather than filled out for symmetry.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Each platform's jobs MUST be able to reach a conclusion independently of any other
  platform's jobs.
- **FR-002**: The set of jobs that run, and the commands they run, MUST be unchanged for a
  repository that has runners for every platform. This is a restructuring, not a change in coverage.
- **FR-003**: No job may declare a dependency on a job belonging to another platform.
- **FR-004**: Runner labels MUST remain sufficient to route jobs to the correct machines without
  editing workflow files, so that a fork registering a runner with the documented labels needs no
  fork-specific workflow changes.
- **FR-005**: Contributor documentation MUST state, per workflow, the platform and runner labels it
  requires.
- **FR-006**: The change MUST identify every branch-protection or required-check reference that
  names a workflow or job whose identity changes.
- **FR-007**: Workflow triggers MUST NOT change. Whether macOS and Windows suites run at pull-request
  time is a cost decision reserved to the maintainers (#5330), and this feature is a restructuring
  that makes such a decision implementable rather than one that takes it.
- **FR-008**: Contributor documentation MUST state how to run the suites on hardware that cannot
  serve every platform, including which knobs affect cost and reliability on constrained machines.
- **FR-009**: The four workflows that are not restructured MUST be audited and their triggers,
  runner labels and platform coupling recorded, so that #5330 and #5146 receive evidence rather than
  competing changes. `windows.yml` and `windows-e2e.yml` carry the same cross-platform coupling as
  `ci.yml` and must be named as such, without being changed here.
- **FR-010**: Integration concurrency and failed-example retry MUST be readable from repository
  variables, each defaulting to the value in use today. With no variable set, the commands executed
  MUST be byte-identical to those executed before the change, so the default path is a no-op for the
  upstream repository and a fork can tune without editing a workflow file.
- **FR-011**: Variable values MUST be visible in the run log. A tuning knob whose setting cannot be
  recovered from a completed run turns a later investigation into guesswork.
- **FR-012**: A checked-in script MUST derive, from the workflow files, the set of jobs with their
  runner labels, commands and `needs` edges, so that equivalence before and after the change is
  shown by running it at both revisions rather than asserted in prose.
- **FR-013**: That script MUST fail when a `needs` edge crosses a platform boundary, so the property
  the split establishes is enforced rather than left to review. It MUST NOT assert against a frozen
  baseline of job names: a snapshot that has to be updated whenever a job is legitimately added
  becomes a maintenance cost that earns nothing.
- **FR-014**: Jobs MUST be grouped into three capability tiers. The boundary is **who benefits from
  the job's output**, not whether it compiles something:
  - **Conformance** — formatting, linting and nix evaluation. Every collaborator benefits: it is
    what keeps people who never speak to each other writing consistent code. Requires a dev shell
    and nothing else, and is relevant to any repository holding the source.
  - **Verification** — unit, integration, cluster and boot-sync suites. Whoever is changing the code
    benefits, and so does any downstream consumer who pins an output, since they need to know it
    still builds. Requires built derivations and, for the cluster suites, a machine able to host a
    local cluster.
  - **Publication** — installers, container images, cache population and published documentation.
    Only the canonical repository's audience benefits; a fork producing them serves nobody, and it
    generally cannot, lacking the credentials. Requires secrets the repository owner holds.

  A build existing solely to feed a publication job is publication, whatever it compiles:
  `build-gate-windows` produces Windows cross-compilation inputs consumed only by `attic-cache`, so
  its beneficiary is the cache rather than anyone changing code.
- **FR-015**: Every workflow MUST target exactly one platform. A tier spanning two platforms in one
  file reintroduces the coupling this feature removes, because the jobs a repository cannot serve
  again prevent a conclusion.
- **FR-016**: Each tier workflow MUST be independently disableable through the repository's Actions
  settings, without affecting another tier or platform. Granularity is delivered by the file
  boundary, since GitHub disables workflows rather than jobs.
- **FR-017**: A job that cannot succeed without repository credentials MUST NOT run where those
  credentials are absent. `attic-cache` is the present example: it consumes `secrets.ATTIC_TOKEN`,
  and its guard admits same-repository pull requests, so a fork running its own pull requests reaches
  the job and fails on a missing token. Being able to disable the tier does not satisfy this: the
  guard must hold without anyone intervening.

  The `secrets` context is available in neither job-level nor step-level `if:` conditions, so the
  guard cannot test the secret directly. It MUST therefore be expressed as a preceding job that maps
  the secret into an output, with the guarded job testing that output through `needs`, which is
  available to a job-level `if:`.
- **FR-018**: A repository MUST be able to declare that it has no runners of a given kind, and every
  job requiring that kind MUST then report as skipped rather than queue. The declarations are the
  repository variables `HAS_MACOS_RUNNER`, covering every job on macOS labels, and `HAS_NIX_RUNNER`,
  covering every job on `nix-enabled-runners`. Only the exact value `false` disables, so an unset
  variable preserves current behaviour and satisfies FR-010 and SC-006.

  Both are required for the same reason. Without `HAS_NIX_RUNNER` a repository with no self-hosted
  Linux runners reproduces, on Linux, precisely the indefinite queue this feature removes for macOS.

  A declaration must not be able to empty a repository's coverage. `HAS_NIX_RUNNER=false` would
  otherwise skip every job, since every nix-tier job needs nix, leaving a green pull request that
  attests only that nothing ran. FR-019 is what prevents that.
- **FR-019**: At least one workflow MUST require neither nix nor a self-hosted runner, and MUST
  carry no capability guard, so that every repository holding the source reports on every pull
  request whatever hardware it owns. The membership rule MUST be stated in the workflow so the
  boundary does not blur, and it has two halves: a check belongs there if it invokes no nix command
  **and** its subject is the repository as any contributor sees it.

  The second half is not redundant with the first. `check-docker-boot-sync-cleanup.sh` only greps,
  so it satisfies the mechanical half, but what it guards — container teardown after the boot-sync
  suite — matters solely because self-hosted runners persist between jobs, where a leaked container
  holds its project name, its ports and its disk against whatever is scheduled next. A repository
  with no self-hosted fleet can never encounter the failure it prevents. Such a check stays with the
  machine whose resources it protects.

  Duplicating those checks against the nix-tier copies is intended, not an oversight. It keeps the
  change additive, avoids renaming existing status checks, and leaves the hosted copies reporting
  when the self-hosted fleet is saturated or unavailable.

  Unlike `secrets`, the `vars` context *is* available to a job-level `if:`, so this needs no
  mapping job. It MUST NOT be expressed as a gate job that other jobs depend on: such a job would
  have to run on some platform, and the macOS jobs depending on it would create exactly the
  cross-platform `needs` edge FR-015 and SC-005 forbid.

  This complements rather than replaces FR-016. Disabling a workflow is invisible on a pull request,
  so a repository that later acquires a runner has nothing reminding it to re-enable anything; a
  skipped job appears in the checks list on every pull request until the declaration changes.
  Disabling is the mechanism for declining a tier one *does not want*; the variable is the mechanism
  for declaring a platform one *does not have*.

### Key Entities

- **Platform job set**: the jobs in `ci.yml` sharing a platform, identified by their `runs-on`
  labels. Linux (16 jobs, `nix-enabled-runners`) and macOS (5 jobs,
  `[self-hosted, macOS, ARM64, cardano-wallet]`) are the two present today.
- **Run conclusion**: the success or failure a workflow reports once all its jobs finish. A queued
  job that no runner can serve prevents it indefinitely — the failure mode this feature removes.
- **Cross-platform dependency**: a `needs` edge between job sets. None exists today; the value of
  this change depends on none being introduced.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a repository with runners for one platform only, a pull request produces at least
  one workflow with a success or failure conclusion.
- **SC-002**: In a repository with runners for every platform, the set of jobs executed for a pull
  request is identical to the set executed before this change.
- **SC-003**: Rerunning one platform's workflow executes no job belonging to another platform.
- **SC-004**: Every workflow's runner requirements can be found in contributor documentation without
  reading a workflow file.
- **SC-005**: No `needs` edge crosses a platform boundary, verifiable by inspection of the workflow
  files.
- **SC-006**: With no repository variables set, the commands executed for a pull request are
  identical to those executed before the change.
- **SC-007**: A fork can change integration concurrency and retry without editing a tracked file, and
  the values used are recoverable from the run log.
- **SC-008**: The triggers, runner labels and platform coupling of all five workflows are recorded in
  contributor documentation, including that `windows.yml` and `windows-e2e.yml` retain the coupling
  this feature removes from `ci.yml`.
- **SC-009**: Running the comparison script at the revision before this change and at the revision
  after it produces the same set of jobs, runner labels and commands, differing only in which file
  each job is declared in.
- **SC-010**: Introducing a `needs` edge across the platform boundary makes the script fail.
- **SC-011**: Every workflow names runner labels for exactly one platform.
- **SC-012**: Disabling one tier's workflow leaves every other tier and platform running.
- **SC-013**: A repository without the publication credentials can run the conformance and
  verification tiers to a conclusion, and no job fails for want of a secret it was never going to
  have.
- **SC-014**: With `ATTIC_TOKEN` unset, the cache job reports as skipped rather than failed, without
  the repository owner disabling anything.
- **SC-015**: With `HAS_MACOS_RUNNER` set to `false`, every macOS workflow reaches a conclusion
  within the time a runner assignment would take, with all its jobs reported as skipped, and the
  pull request shows no indefinitely pending check.
- **SC-016**: With `HAS_MACOS_RUNNER` unset, the jobs executed are identical to those executed
  before this change, so the declaration is opt-in and upstream behaviour is unaffected.
- **SC-017**: With `HAS_NIX_RUNNER` set to `false`, every job needing nix reports as skipped, no job
  queues awaiting a runner the repository does not have, and the hosted conformance workflow still
  reaches a success or failure conclusion.
- **SC-018**: Every job in the six workflows carries the declaration guard matching its runner kind,
  verifiable by inspection of the workflow files.

## Assumptions

- The five macOS jobs and the sixteen Linux jobs are independent as of `d3d170d02`, verified by
  inspecting every `needs` edge in `ci.yml`. If a future edge crosses the boundary, the split stops
  being purely structural and the dependency has to be resolved first.
- Windows needs no attention here. `build-gate-windows` cross-compiles on Linux and belongs to the
  Linux set; the Windows suites already live in separate workflow files.
- Forks are expected. The repository is public and carries contribution guidelines, so a fork being
  unable to run CI is a defect in the scaffold rather than an acceptable consequence of not being the
  upstream organisation.
- Provisioning runners for every platform is not affordable for every contributor. A community
  maintainer may have one machine, and macOS and Windows hardware in particular may be out of reach.
  The scaffold should degrade to a partial but conclusive verdict rather than to none.
- No change to what is tested is intended or implied. A reviewer should be able to confirm that the
  same commands run on the same machines, and only the file they are declared in changes.
- Work whose cadence is release-driven rather than change-driven — benchmarks, release preparation,
  publishing — already lives in separate workflows (`linux-benchmarks.yml`,
  `restoration-benchmarks.yml`, `release.yml`, `publish.yml` and others) and is outside this
  feature. The tiering here addresses only what remains bundled inside `ci.yml`, which runs on every
  push and pull request.
- The motivating case is a downstream consumer that pins this repository as a dependency and builds
  it themselves. Such a fork needs conformance and verification, including the specific outputs its
  consumer pins, and needs nothing from publication: no installer it ships, no image it serves, no
  cache it writes. Today it cannot express that, so it maintains a parallel workflow of its own —
  duplicated effort that drifts from upstream and benefits nobody. The measure of this feature is
  whether such a fork can delete its parallel workflow and disable tiers instead.
