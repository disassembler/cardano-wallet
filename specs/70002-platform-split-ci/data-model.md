# Data Model: Platform and tier split of the CI workflow

No runtime data. The entities are the structures the workflow files describe and the comparison
script derives from them.

## Entities

### Platform

The machine class a job runs on, identified by its `runs-on` labels.

| Platform | Labels | Servable by a fork? |
|---|---|---|
| Linux | `nix-enabled-runners` | Yes, with a self-hosted Linux runner carrying that label |
| macOS | `[self-hosted, macOS, ARM64, cardano-wallet]` | Only with Apple hardware and all four labels |

Windows appears in `windows.yml` under `windows-2025-vs2026`, an organisation-specific larger runner
outside this feature's write set.

**Invariant**: a workflow names labels for exactly one platform (FR-015).

### Tier

What a repository must possess to run a job, and who consumes the result.

| Tier | Requires | Output consumed by |
|---|---|---|
| Conformance | A dev shell | Whoever runs it |
| Verification | Built derivations; a machine able to host a local cluster for the cluster suites | Whoever runs it, and downstream consumers who pin the built outputs |
| Publication | Credentials the repository owner holds | The repository owner's release process |

The boundary is the consumer, not whether the job compiles anything: a build whose result a
downstream consumer pins is verification; a build whose result only the owner ships is publication.

### Workflow

One file, one tier, one platform. The unit of enablement, because GitHub disables workflows rather
than jobs.

```text
ci-<tier>-<platform>.yml
```

Populated where jobs exist; the matrix is not filled out for symmetry.

### Gate

A `nix build` that realises the derivations a tier's jobs consume. Today gates are jobs with `needs`
edges pointing at them. After the split they are steps, because a workflow cannot depend on a job in
another file.

| Gate | Builds |
|---|---|
| `build-gate` | test and runtime derivations for the verification suites |
| `build-gate-quality` | `devShells.x86_64-linux.default.inputDerivation` |
| `build-gate-artifacts` | packaging inputs |
| `build-gate-windows` | Windows cross-compilation inputs |
| `build-gate-mac` | the macOS equivalents |

**Assumption**: runners have a persistent nix store, so a repeated gate is a no-op rather than a
rebuild.

### Job matrix entry

What the comparison script derives per job, and the unit of the equivalence claim:

```text
(workflow, job id, platform, runner labels, needs[], commands[])
```

Equivalence before and after the change means the same set of entries modulo the `workflow` field —
that field changing is the point.

## Transformation

```text
ci.yml (21 jobs, 2 platforms, 5 gates, 1 conclusion)
  │
  ├── ci-conformance-linux.yml    quality-checks, nix-check
  ├── ci-conformance-macos.yml    mac-nix-check
  ├── ci-verification-linux.yml   unit-tests, integration, local-cluster, boot-syncs
  ├── ci-verification-macos.yml   mac-local-cluster
  ├── ci-publication-linux.yml    artifacts ×3, docker, docker-boot-sync, attic-cache
  └── ci-publication-macos.yml    mac-package-intel, mac-package-silicon
```

Two entries change beyond their `workflow` field, and both are recorded as decisions:

- `nix-check` loses `needs: build-gate`. Its only command is `nix --version`.
- `attic-cache` loses three `needs` edges and gains the corresponding gate steps.

## Invariants

- Every workflow names labels for exactly one platform (SC-011).
- No `needs` edge crosses a platform boundary; the checker fails if one is introduced (SC-010).
- With no repository variables set, every command is byte-identical to `d3d170d02` (SC-006).
- Disabling one workflow leaves the others running (SC-012).
- A repository lacking publication credentials can run conformance and verification to a conclusion,
  and no job fails for want of a secret it was never going to have (SC-013).
