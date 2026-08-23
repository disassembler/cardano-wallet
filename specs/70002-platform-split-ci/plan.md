# Implementation Plan: Platform and tier split of the CI workflow

**Branch**: `70002-platform-split-ci` | **Date**: 2026-08-13 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/70002-platform-split-ci/spec.md`
**Related**: unblocks [#5330](https://github.com/cardano-foundation/cardano-wallet/issues/5330),
advances [#5146](https://github.com/cardano-foundation/cardano-wallet/issues/5146)

## Summary

`ci.yml` declares 21 jobs across two platforms in one workflow, so a repository that cannot serve
one platform never reaches a conclusion — sixteen jobs pass, five queue forever, and the pull
request has no verdict. The jobs also differ in what a repository must *have* to run them: a dev
shell, built derivations, or credentials it may not hold.

Split `ci.yml` along both axes into single-platform, single-tier workflows: conformance,
verification and publication, each per platform. Every workflow then concludes on whatever runners
exist, and a repository disables a tier or a platform through Actions settings without touching a
tracked file. Integration concurrency and retry move to repository variables defaulting to today's
values. A checked-in script derives the job matrix from the workflow files so the equivalence claim
is re-runnable evidence, and fails if a `needs` edge ever crosses a platform boundary again.

## Technical Context

**Language/Version**: GitHub Actions workflow YAML; Bash for the comparison script
**Primary Dependencies**: `nix` on self-hosted runners; `actionlint` for validation; `yq` or Python
with PyYAML for the comparison script
**Storage**: N/A
**Testing**: `actionlint` on every workflow; the comparison script run at both revisions; a live run
on a fork with Linux-only runners
**Target Platform**: GitHub Actions, self-hosted Linux and macOS runners
**Project Type**: CI configuration for a Haskell monorepo
**Performance Goals**: no increase in wall-clock for a repository with all runners; each tier
workflow concludes independently
**Constraints**: triggers unchanged (FR-007); commands unchanged with no variables set (FR-010);
every workflow single-platform (FR-015); no frozen baseline in the checker (FR-013)
**Scale/Scope**: 21 jobs redistributed across six workflow files, one new script, one documentation
page

## Constitution Check

| Principle | Status | Notes |
|---|---|---|
| Maintenance-first stability | OK | No product code changes. The risk is CI regression, which the comparison script and a live run are designed to catch. |
| Era-aware design | N/A | No domain types involved. |
| Type safety as security | N/A | No Haskell changes. |
| Formal specification | OK | `specifications/api/swagger.yaml` untouched. |
| Reproducible builds | OK | Same `nix build` invocations; no dependency or pin changes. The split assumes persistent runner stores, stated in the spec's Edge Cases. |
| Comprehensive testing | OK | Same suites on the same machines. Coverage is unchanged by construction and verified mechanically. |
| Code quality gates | OK | `actionlint` and `shellcheck` cover the new files; `scripts/shellcheck.sh` already lints `scripts/`. |

No violations, so **Complexity Tracking** is empty.

## Project Structure

### Documentation (this feature)

```text
specs/70002-platform-split-ci/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── workflow-surface.md
└── tasks.md            # /speckit.tasks output — not created here
```

### Source Code (repository root)

Expected write set:

```text
.github/workflows/ci.yml                    (retained as conformance/linux — the baseline)
.github/workflows/ci-conformance-hosted.yml (new — no nix, no self-hosted runner, no guard)
.github/workflows/ci-conformance-macos.yml  (new)
.github/workflows/ci-verification-linux.yml (new)
.github/workflows/ci-verification-macos.yml (new)
.github/workflows/ci-publication-linux.yml  (new)
.github/workflows/ci-publication-macos.yml  (new)
scripts/ci/check-workflow-platforms.sh      (new)
docs/site/src/contributor/how/continuous-integration.md
```

Must not change:

```text
.github/workflows/macos-unit-tests.yml
.github/workflows/macos-integration.yml
.github/workflows/windows.yml
.github/workflows/windows-e2e.yml
lib/**
specifications/api/swagger.yaml
```

The four untouched workflows are audited into documentation only (FR-009). Editing any of them means
the change has crossed into #5330's territory, which FR-007 excludes.

**Structure Decision**: one workflow per (tier, platform) pair that has jobs — six today. `ci.yml`
keeps its name and becomes conformance/Linux, the baseline that must always pass: it is the tier
relevant to every repository holding the source, and keeping the name preserves one existing
required-status-check identity, reducing the branch-protection migration by one entry.

## Job Mapping

Derived from `ci.yml` at `d3d170d02`. Every job is accounted for; `needs` edges are shown as they
exist today.

| Tier | Platform | Jobs | Gate |
|---|---|---|---|
| Conformance | Linux | `quality-checks`, `nix-check` | `build-gate-quality` |
| Conformance | macOS | `mac-nix-check` | `build-gate-mac` |
| Verification | Linux | `unit-tests`, `integration`, `local-cluster`, `boot-syncs` | `build-gate` |
| Verification | macOS | `mac-local-cluster` | `build-gate-mac` |
| Publication | Linux | `artifacts-package`, `artifacts-wallet-key-export`, `artifacts-shell`, `docker`, `docker-boot-sync`, `attic-cache` | `build-gate-artifacts`, `build-gate-windows`, `build-gate-quality` |
| Publication | macOS | `mac-package-intel`, `mac-package-silicon` | `build-gate-mac` |

Two jobs do not fit the mapping cleanly and are resolved in research.md:

- **`nix-check`** declares `needs: build-gate` but its only step is `nix --version`. Keeping the edge
  would drag the verification gate into the conformance tier and defeat the tier's purpose.
- **`attic-cache`** declares `needs` on three gates spanning two tiers. Workflows cannot share jobs,
  so it must carry its own gate steps.

## Verification Strategy

```sh
# every workflow parses and references only known contexts
nix run nixpkgs#actionlint -- -ignore 'label ".*" is unknown' .github/workflows/*.yml

# the job matrix is unchanged, and no needs edge crosses a platform
scripts/ci/check-workflow-platforms.sh --print   # evidence for the PR body
scripts/ci/check-workflow-platforms.sh           # asserts the invariant, exit non-zero on breach

# shellcheck, as CI already applies to scripts/
nix run nixpkgs#shellcheck -- scripts/ci/check-workflow-platforms.sh
```

The equivalence evidence is the `--print` output at `d3d170d02` and at the branch tip, diffed. A live
run on a Linux-only fork demonstrates SC-001, which no static check can.

## Risks And Mitigations

- **A required status check disappears.** Splitting changes check names. Identify every branch
  protection reference before merge (FR-006); the change is not complete until the maintainers know
  which rules to update.
- **A job silently stops running.** The comparison script exists for this. Run it at both revisions
  and paste both outputs.
- **Gate duplication costs time on cold runners.** Each tier workflow runs its own gate step. On a
  persistent store this is a no-op; on ephemeral runners it would be a rebuild per tier. Stated in
  the spec's Edge Cases as an assumption rather than discovered later.
- **Scope creep into triggers.** FR-007 excludes them. If a reviewer asks for a `pull_request`
  trigger on macOS, that is #5330's decision and belongs in its own change.
- **The PR is too large to review.** Mitigated by making the diff mechanical and the evidence
  re-runnable, and by touching no product code. If a maintainer still balks, the fallback is to land
  the platform split alone and follow with tiering.
