# Tasks: Platform and tier split of the CI workflow

**Input**: Design documents from `/specs/70002-platform-split-ci/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/workflow-surface.md, quickstart.md
**Related**: unblocks [#5330](https://github.com/cardano-foundation/cardano-wallet/issues/5330), advances [#5146](https://github.com/cardano-foundation/cardano-wallet/issues/5146)

**Tests**: Required. The spec's User Scenarios section is mandatory, and SC-009/SC-010 are
mechanical checks the feature itself must provide.

**Organization**: By user story. The tier separation belongs to User Story 1 rather than a phase of
its own: a platform split alone gives a fork a *conclusive* verdict, but a red one, because
`attic-cache` fails on a secret it cannot hold. US1 is not delivered until a fork can disable that.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1, US2, US3 — maps to the user stories in spec.md
- Commands run from the repository root

## Path Conventions

Workflows in `.github/workflows/`, scripts in `scripts/ci/`, contributor documentation in
`docs/site/src/contributor/how/`.

---

## Phase 1: Setup

**Purpose**: Capture the state the change must preserve, before changing anything.

- [X] T001 Capture the baseline job matrix to `/tmp/ci-matrix-before.txt` using the extractor in quickstart.md, and record the revision it was taken at
- [X] T002 [P] Confirm the validation tools run: `nix run nixpkgs#actionlint -- --version` and `nix run nixpkgs#shellcheck -- --version`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The checker that every later phase is verified against.

**⚠️ CRITICAL**: Written before the split, so it can be shown to report the *current* state
accurately. A checker written after a refactor tends to pass vacuously.

- [X] T003 Write `scripts/ci/check-workflow-platforms.sh` to the contract in contracts/workflow-surface.md: assert one platform per workflow and no `needs` edge across a platform boundary; `--print` emits `<workflow> <job-id> <platform> <runner-labels> <needs...> <commands...>` in a stable order; exit `0`/`1`/`2` as specified
- [X] T004 Run `scripts/ci/check-workflow-platforms.sh` at HEAD and confirm it passes against the unsplit tree, and that `--print` lists all 21 `ci.yml` jobs
- [X] T005 Prove the checker fails when it should: add a `needs` edge from a Linux job to `build-gate-mac` in `.github/workflows/ci.yml`, confirm a non-zero exit naming the job and edge, then revert the edit
- [X] T006 [P] Run `nix run nixpkgs#shellcheck -- scripts/ci/check-workflow-platforms.sh` and fix any finding

**Checkpoint**: The invariant is enforceable and demonstrably not vacuous.

---

## Phase 3: User Story 1 — A Fork With Runners For One Platform (Priority: P1) 🎯 MVP

**Goal**: A repository that can serve one platform gets a conclusive, useful verdict, and can
decline the tiers it has no use for.

**Independent Test**: On a fork with Linux-only runners, open a pull request and confirm at least one
workflow reaches a conclusion; disable the publication workflow and confirm the others still run.

### Implementation for User Story 1

- [X] T007 [US1] Reduce `.github/workflows/ci.yml` to conformance/Linux — `build-gate-quality` and `quality-checks`. The file keeps its name as the always-on baseline, preserving one required-check identity. `nix-check` is dropped rather than moved: once `build-gate-quality` opens with `nix --version` it is a duplicate of that step, and it paid a full-history clone to run one command (research.md §Decisions). Triggers unchanged
- [X] T008 [P] [US1] Create `.github/workflows/ci-conformance-macos.yml`: `mac-nix-check` alone, with no build gate. Its two commands are evaluation-only, so gating them reproduces the inversion `c90183ec2` introduced (research.md §Decisions)
- [X] T009 [US1] Create `.github/workflows/ci-verification-linux.yml`: `unit-tests`, `integration`, `local-cluster`, `boot-syncs`, with `build-gate`'s build as a step. Add `INTEGRATION_JOBS` (default `6`) and `TESTS_RETRY_FAILED` (default `1`) as repository variables, and echo both before the suite starts (FR-010, FR-011)
- [X] T010 [P] [US1] Create `.github/workflows/ci-verification-macos.yml`: `mac-local-cluster`, with `build-gate-mac`'s build as a step
- [X] T011 [US1] Create `.github/workflows/ci-publication-linux.yml`: `artifacts-package`, `artifacts-wallet-key-export`, `artifacts-shell`, `docker`, `docker-boot-sync`, `attic-cache`. `attic-cache` loses its three `needs` edges and gains the corresponding gate builds as steps (research.md §Decisions)
- [X] T012 [P] [US1] Create `.github/workflows/ci-publication-macos.yml`: `mac-package-intel`, `mac-package-silicon`, with `build-gate-mac`'s build as a step
- [X] T012a [US1] Guard `attic-cache` on the secret being present (FR-017). The `secrets` context is available in neither job-level nor step-level `if:`, so add a preceding job in `ci-publication-linux.yml` that maps `secrets.ATTIC_TOKEN` into an output — `env: TOKEN: ${{ secrets.ATTIC_TOKEN }}` then `echo "value=${TOKEN:+true}" >> "$GITHUB_OUTPUT"` — and gate `attic-cache` with `needs:` plus `if: needs.<gate>.outputs.value == 'true'`. Keep the existing same-repository condition alongside it
- [X] T013 [US1] Confirm every job from the original `ci.yml` now lives in exactly one workflow, none defined twice, and that the only job absent altogether is `nix-check`, deleted per T007
- [X] T013a [US1] Add `if: vars.HAS_MACOS_RUNNER != 'false'` to every job in the three macOS workflows and `if: vars.HAS_NIX_RUNNER != 'false'` to every job on `nix-enabled-runners`, so a repository declaring the absence of a runner kind gets skips rather than an indefinite queue (FR-018). Guard every job individually — a gate job would have to run on some platform and would reintroduce the cross-platform `needs` edge the checker rejects
- [X] T013b [US1] Create `.github/workflows/ci-conformance-hosted.yml` on `ubuntu-latest` with no capability guard, so no declaration can leave a repository with zero coverage (FR-019). State the membership rule in the file, both halves: no nix command, **and** a subject that is the repository rather than the self-hosted fleet. `check-docker-boot-sync-cleanup.sh` passes the first and fails the second — it guards teardown that matters only because those runners persist — so it stays in `ci.yml` where it already was
- [X] T014 [US1] Run `nix run nixpkgs#actionlint -- -ignore 'label ".*" is unknown' .github/workflows/*.yml` and resolve every finding

### Verification for User Story 1

- [X] T015 [US1] Run `scripts/ci/check-workflow-platforms.sh` and confirm it passes: one platform per workflow, no cross-platform `needs`
- [X] T016 [US1] Capture the matrix again and diff against T001 ignoring the workflow-file field. Seven differences are permitted, each recorded in research.md §Decisions: (1) `mac-nix-check` loses its gate edge; (2) `nix-check` is deleted outright; (3) `attic-cache` loses `build-gate-quality`, gains an `attic-token` edge and that gate's build as a step; (4) `attic-token` is new; (5) every `build-gate*` job gains its platform's nix check as opening steps; (6) `build-gate-mac` appears twice rather than once; (7) `checks` and `shellcheck` are new on `ubuntu-latest`. Record the diff for the pull request (SC-002, SC-006, SC-009)
- [X] T016a [US1] State in the pull request what the matrix diff does **not** capture: the extractor reads `runs-on`, `needs` and `run` commands only, so the `if:` guards added by T013a are invisible to it. Their evidence is the per-job audit and the live run, not this diff (SC-018)
- [ ] T017 [US1] Push the branch to a fork with Linux-only runners, open a pull request, and confirm the three Linux workflows reach a conclusion while the three macOS workflows stay queued and block nothing (SC-001). Record the run URLs
- [ ] T018 [US1] On that fork, with `ci-publication-linux.yml` still enabled and `ATTIC_TOKEN` unset, confirm `attic-cache` reports as **skipped** rather than failed (SC-014). Then disable that workflow in Actions settings and confirm conformance and verification still run to a conclusion (SC-012, SC-013)

**Checkpoint**: A fork gets a green verdict from the tiers it can run, and declines the rest.

---

## Phase 4: User Story 2 — Knowing Which Checks A Fork Can Expect To Run (Priority: P2)

**Goal**: A maintainer can determine what their infrastructure can serve without reading workflow
files.

**Independent Test**: A contributor finds each workflow's platform and runner labels in the
contributor documentation.

- [X] T019 [US2] Add the workflow table to `docs/site/src/contributor/how/continuous-integration.md`: every workflow with its tier, platform, runner labels and triggers, taken from research.md §Current-state inventory (SC-004, SC-008)
- [X] T020 [P] [US2] Document `INTEGRATION_JOBS` and `TESTS_RETRY_FAILED` in the same page: defaults, effect, and when to lower concurrency — the integration suite runs one cluster and races against block production, and those races widen under CPU contention
- [X] T021 [US2] Record the audit of the four unmodified workflows in the same page, stating that `windows.yml` and `windows-e2e.yml` retain the cross-platform coupling removed from `ci.yml`, and that `windows-2025-vs2026` is an organisation-specific runner no fork can serve (FR-009)

**Checkpoint**: The requirements are discoverable without reading YAML.

---

## Phase 5: User Story 3 — Rerunning One Platform (Priority: P3)

**Goal**: One platform's jobs can be rerun without repeating the other's.

**Independent Test**: Rerun one workflow and confirm no job from another platform executes.

- [ ] T022 [US3] On the fork pull request from T017, rerun one workflow and confirm from the run list that no job belonging to another platform or tier re-executes (SC-003)

**Checkpoint**: A transient failure costs one workflow, not the whole run.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T023 Identify every branch-protection or required-status-check reference naming a workflow or job whose identity changes: try `gh api repos/cardano-foundation/cardano-wallet/branches/master/protection --jq '.required_status_checks.contexts'`, and if it is not readable without admin, state in the pull request that the list must come from the maintainers (FR-006)
- [X] T024 [P] Re-run `actionlint` over every workflow and `shellcheck` over the new script
- [X] T025a Make `scripts/ci/check-docker-boot-sync-cleanup.sh` derive its subject instead of naming it. Its seven `require_literal` assertions targeted a hardcoded `.github/workflows/ci.yml`, so moving `docker-boot-sync` to the publication tier broke all seven at once; hardcoding a different path would leave the same trap armed for the next move. Locate the workflow declaring the job, and exit non-zero if none or more than one does
- [X] T025b Prove that check is not vacuous: rename the `docker-boot-sync` job, confirm the script exits `1` naming the missing subject, then revert
- [X] T025 Confirm the write set: `git diff --name-only upstream/master...HEAD` lists only the seven new workflows, `ci.yml`, `scripts/ci/check-workflow-platforms.sh`, `scripts/ci/check-docker-boot-sync-cleanup.sh`, the documentation page and `specs/70002-platform-split-ci/`. `macos-unit-tests.yml`, `macos-integration.yml`, `windows.yml`, `windows-e2e.yml`, `lib/**` and `specifications/api/swagger.yaml` must not appear
- [ ] T026 Commit as `ci: split the CI workflow by platform and capability tier`, and write the pull request body stating that it unblocks #5330 without closing it, advances #5146's contributor-guide criterion only, and including the T016 diff and the T017/T018 run URLs

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies. T001 must run before any workflow edit or the baseline is lost
- **Foundational (Phase 2)**: depends on Setup. Blocks all user stories — nothing is verifiable without the checker
- **User Story 1 (Phase 3)**: depends on Phase 2
- **User Story 2 (Phase 4)**: depends on the split existing (T007–T013) for the table to describe reality
- **User Story 3 (Phase 5)**: depends on T017, which produces the run to rerun
- **Polish (Phase 6)**: depends on all desired stories

### Task-Level Dependencies

- T001 → every task that edits a workflow (baseline first)
- T003 → T004, T005, T006, T015
- T007–T013 → T014 → T015 → T016
- T017 → T018, T022
- T007–T013 → T019, T021

### File Contention

`ci.yml` is touched by T013 only; each new workflow is written by exactly one task. The
documentation page is touched by T019, T020 and T021, which are therefore not all parallel — T020
carries `[P]` because it edits a distinct section, but sequence it after T019 creates the page
structure.

### Parallel Opportunities

- T008, T010, T012 — the three macOS workflows, distinct files, once the Linux equivalents establish the pattern
- T002 and T006 are independent of everything else
- T024 runs alongside T023

---

## Parallel Example: after T007 establishes the pattern

```bash
Task: "T008 create .github/workflows/ci-conformance-macos.yml"
Task: "T010 create .github/workflows/ci-verification-macos.yml"
Task: "T012 create .github/workflows/ci-publication-macos.yml"
```

---

## Implementation Strategy

### MVP First (User Story 1)

1. Phase 1 — capture the baseline; it cannot be recovered later
2. Phase 2 — the checker, proven to fail when it should
3. Phase 3 — the split, verified mechanically and then live on a fork

Stop there and the feature is deliverable: a fork gets a usable verdict. Documentation and rerun
proof are additive.

### Fallback If Review Stalls

The plan's risk register names this: six new files touching every job in the main workflow is a lot
to ask a maintainer to own. If the pull request stalls, the fallback is to land the platform split
alone — `ci.yml` plus `ci-macos.yml`, a pure move with no tiering — and propose tiering separately
with the first as evidence. Phase 3 is ordered so that T007, T008, T010 and T013 alone constitute
that smaller change.

---

## Notes

- Triggers are copied verbatim (FR-007). If review asks for `pull_request` on macOS, that is #5330's
  decision and belongs in its own change
- The intended deviations from a pure move are enumerated in T016 and justified in research.md
  §Decisions. Anything else appearing in the T016 diff is a mistake, not a judgement call
- The split assumes runners with a persistent nix store; on ephemeral runners the per-tier gate steps
  would be rebuilds rather than no-ops
- `.specify/scripts/bash/common.sh` is modified in the working tree and must not be committed on this
  branch — it belongs to upstream PR #5372
