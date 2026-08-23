# Quickstart: Platform and tier split of the CI workflow

All commands run from the repository root. `actionlint` and `shellcheck` come from nixpkgs, so no dev
shell is needed for the validation steps.

## Baseline

Capture the job matrix before touching anything. This is half the evidence the pull request needs.

```sh
git rev-parse --short HEAD                      # expect d3d170d02 or a descendant
python3 - <<'PY' > /tmp/ci-matrix-before.txt
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')):
    d = yaml.safe_load(open(f)) or {}
    for j, v in (d.get('jobs') or {}).items():
        n = v.get('needs'); n = [n] if isinstance(n, str) else (n or [])
        cmds = [s.get('run','').strip().splitlines()[0][:60]
                for s in v.get('steps',[]) if s.get('run')]
        print(f, j, v.get('runs-on'), sorted(n), cmds, sep='|')
PY
wc -l /tmp/ci-matrix-before.txt
```

Expect 21 rows from `ci.yml` plus the rows from the other workflows.

## Step 1 — Write the checker first

`scripts/ci/check-workflow-platforms.sh`, to the contract in contracts/workflow-surface.md. Writing
it before the split means it can be run against the current tree to confirm it reports the existing
state accurately — a checker that passes vacuously is worse than none.

```sh
scripts/ci/check-workflow-platforms.sh          # must pass at HEAD, before any split
scripts/ci/check-workflow-platforms.sh --print | head
nix run nixpkgs#shellcheck -- scripts/ci/check-workflow-platforms.sh
```

Prove it fails when it should, by temporarily adding a cross-platform `needs` edge to `ci.yml` and
confirming a non-zero exit and a message naming the job. Revert immediately.

## Step 2 — Split, one tier at a time

Order by risk, cheapest first. After each, run the checker and `actionlint`.

1. `ci-conformance-linux.yml` — `quality-checks`, `nix-check`, gate `build-gate-quality` as a step.
   `nix-check` drops `needs: build-gate`; its only command is `nix --version` (research.md).
2. `ci-conformance-macos.yml` — `mac-nix-check`, gate `build-gate-mac` as a step.
3. `ci-verification-linux.yml` — `unit-tests`, `integration`, `local-cluster`, `boot-syncs`, gate
   `build-gate` as a step. Add the two repository variables here.
4. `ci-verification-macos.yml` — `mac-local-cluster`.
5. `ci-publication-linux.yml` — artifacts ×3, `docker`, `docker-boot-sync`, `attic-cache` with its
   three gate builds inline.
6. `ci-publication-macos.yml` — `mac-package-intel`, `mac-package-silicon`.

```sh
nix run nixpkgs#actionlint -- -ignore 'label ".*" is unknown' .github/workflows/*.yml
scripts/ci/check-workflow-platforms.sh
```

## Step 3 — Prove equivalence

```sh
python3 - <<'PY' > /tmp/ci-matrix-after.txt
# same script as the baseline
PY
diff <(cut -d'|' -f2- /tmp/ci-matrix-before.txt | sort) \
     <(cut -d'|' -f2- /tmp/ci-matrix-after.txt  | sort)
```

Dropping field 1 removes the filename, which is the field intended to change. The diff must be empty
except for the two documented deviations:

- `nix-check` loses `needs: build-gate`
- `attic-cache` loses three `needs` edges and gains the equivalent gate commands as steps

Anything else in that diff is a mistake. Paste it into the pull request either way.

## Step 4 — Identify required checks

```sh
gh api repos/cardano-foundation/cardano-wallet/branches/master/protection \
  --jq '.required_status_checks.contexts' 2>/dev/null \
  || echo "not readable without admin — ask the maintainers which checks are required"
```

Splitting changes check names. List every affected one in the pull request (FR-006). This is not
optional: a required check that no longer exists blocks every future pull request silently.

## Step 5 — Live proof

Static checks cannot demonstrate SC-001, which is about a repository that *cannot* serve a platform.
Push the branch to a fork with Linux-only runners and open a pull request there:

- The three Linux workflows conclude
- The three macOS workflows stay queued and block nothing
- Disabling `ci-publication-linux.yml` in Actions settings leaves conformance and verification running

Record the run URLs in the pull request. That is the evidence for SC-001, SC-012 and SC-013.

## Step 6 — Documentation

Update `docs/site/src/contributor/how/continuous-integration.md`:

- the workflow table from research.md — tier, platform, runner labels, triggers
- what a repository needs to run each tier, and what it loses by disabling one
- the two repository variables and when to lower them
- that `windows.yml` and `windows-e2e.yml` retain the coupling removed from `ci.yml`

## Commit

```text
ci: split the CI workflow by platform and capability tier
```

Conventional Commits. Include the `--print` diff and the fork run URLs in the pull request body, and
state plainly that the change unblocks #5330 without closing it.
