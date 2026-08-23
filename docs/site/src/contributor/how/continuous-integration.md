# Continuous Integration

All CI for `cardano-wallet` runs on [GitHub Actions](https://github.com/cardano-foundation/cardano-wallet/actions). Workflows are defined in [`.github/workflows/`](https://github.com/cardano-foundation/cardano-wallet/tree/master/.github/workflows).

## Workflows

### Core CI

Core CI is split by **platform** and by **tier**. Every workflow targets one platform, so a
repository able to serve some platforms and not others still reaches a conclusion on the ones it can
run. A repository that declares which runners it has (see below) additionally gets the jobs it
cannot serve reported as **skipped**; one that declares nothing leaves them queued, where they block
nothing but stay pending until GitHub times them out after 24 hours.

Tiers group jobs by who benefits from their output, which is also what decides whether a given
repository wants to run them at all:

| Tier | Benefits | Requires |
|------|----------|----------|
| Conformance (hosted) | Every collaborator, including one with no hardware at all | Nothing — GitHub-hosted. Carries checks whose subject is the repository, not the runner fleet |
| Conformance | Every collaborator — it keeps people who never speak writing consistent code | A dev shell |
| Verification | Whoever changes the code, and anyone pinning a built output | Built derivations; a machine able to host a local cluster |
| Publication | Only the canonical repository's audience | `ATTIC_TOKEN` and the runners to build artifacts |

| Workflow | Tier | Platform | Runner labels | Trigger |
|----------|------|----------|---------------|---------|
| `ci-conformance-hosted.yml` | Conformance | Linux (hosted) | `ubuntu-latest` | push, PR, dispatch |
| [`ci.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/ci.yml) | Conformance | Linux | `nix-enabled-runners` | push, PR, dispatch |
| `ci-conformance-macos.yml` | Conformance | macOS | `self-hosted, macOS, ARM64, cardano-wallet` | push, PR, dispatch |
| `ci-verification-linux.yml` | Verification | Linux | `nix-enabled-runners` | push, PR, dispatch |
| `ci-verification-macos.yml` | Verification | macOS | `self-hosted, macOS, ARM64, cardano-wallet` | push, PR, dispatch |
| `ci-publication-linux.yml` | Publication | Linux | `nix-enabled-runners` | push, PR, dispatch |
| `ci-publication-macos.yml` | Publication | macOS | `self-hosted, macOS, ARM64, cardano-wallet` | push, PR, dispatch |

`ci.yml` keeps its name as the baseline that should always pass: conformance is the tier relevant to
any repository holding the source, whatever hardware it has.

A repository that does not publish — a fork, or anyone building from source — can disable
`ci-publication-*` in **Settings → Actions**. The cache job additionally skips itself when
`ATTIC_TOKEN` is absent, so it reports as skipped rather than failing.

Disabling publication is not free, though. `docker-boot-sync` boots the built image and checks it
reaches a syncing state, which is a verification signal rather than a publication one; it sits in
this tier because it consumes the image `docker` produces, and workflows cannot share jobs. Disable
the tier and that test goes with it.

### Declaring what your infrastructure has

Two repository variables let a repository say which runners it does **not** have. Every job for that
runner kind then reports as skipped instead of queueing for a machine that will never arrive.

| Variable | Set it to | Effect |
|----------|-----------|--------|
| `HAS_MACOS_RUNNER` | `false` | Every job in the three `*-macos` workflows skips |
| `HAS_NIX_RUNNER` | `false` | Every job on `nix-enabled-runners` skips — which, today, is every job in the other three workflows |

Only the exact string `false` disables. Anything else, including leaving the variable unset, runs
the jobs — so this is opt-in and changes nothing for a repository that ignores it.

Set them in **Settings → Secrets and variables → Actions → Variables**, or:

```console
$ gh variable set HAS_MACOS_RUNNER --body false
$ gh variable list
```

Prefer this to disabling a workflow when the reason is *"I do not have that hardware"*. A disabled
workflow is invisible: nothing on any pull request indicates it exists, so a repository that later
acquires a runner has nothing to remind it. A skipped job stays in the checks list on every pull
request until the declaration changes. Disabling is the right mechanism for a tier you do not
**want**; the variable is the right one for a platform you do not **have**.

Skipped jobs also satisfy branch protection, where a job that never reports leaves a required check
pending indefinitely.

`HAS_NIX_RUNNER=false` does not leave a repository with nothing. `ci-conformance-hosted.yml` runs on
GitHub-hosted capacity and carries no guard, so it reports on every pull request in every
repository. That is what keeps a green verdict meaningful where the nix tiers are declared away —
something did run, and it was the tier that catches the errors a contributor is most likely to make.

### Failing fast without nix

Every build gate opens with its platform's nix check — `nix --version` on Linux, plus
`nix flake info` on macOS — before invoking `nix build`. A runner missing nix, or missing it from
the service PATH, therefore fails at a named step in seconds rather than somewhere inside a
multi-derivation build.

### Running on partial infrastructure

| You have | Enable | Declare | Expect |
|----------|--------|---------|--------|
| Linux runners only | `ci.yml`, `ci-verification-linux.yml` | `HAS_MACOS_RUNNER=false` | Conformance and verification conclude; macOS jobs report as skipped |
| Linux, and you publish | Add `ci-publication-linux.yml` | — | Requires `ATTIC_TOKEN` for the cache job; other publication jobs run without it |
| macOS as well | The `*-macos` workflows | — | Requires a runner carrying all four labels above |
| No self-hosted runners | `ci-conformance-hosted.yml` (always on) | `HAS_NIX_RUNNER=false`, `HAS_MACOS_RUNNER=false` | The hosted conformance checks run and conclude in seconds; everything needing nix skips, and nothing queues |

Three tuning knobs are read from repository variables by `ci-verification-linux.yml`, each
defaulting to the value used before they were configurable, so leaving them unset changes nothing:

| Variable | Default | Effect |
|----------|---------|--------|
| `INTEGRATION_JOBS` | `6` | `-j` for the integration suite |
| `TESTS_RETRY_FAILED` | `1` | Retry failed examples once |
| `LOCAL_CLUSTER_ERA` | `conway` | Era the local cluster starts in |

Lower `INTEGRATION_JOBS` on a machine with few cores. The integration suite runs a single cluster and
its scenarios race against block production and reward accrual; those races widen under CPU
contention, so an oversubscribed machine produces failures that look like flakes but are really the
tests losing a race. The values in use are echoed at the start of the run.

### Platform-specific

| Workflow | Trigger | Runner labels | Description |
|----------|---------|---------------|-------------|
| [`windows.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/windows.yml) | push, dispatch | `nix-enabled-runners` **and** `windows-2025-vs2026` | Windows build & unit tests |
| [`macos-unit-tests.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/macos-unit-tests.yml) | push, dispatch | `self-hosted, macOS, ARM64, cardano-wallet` | macOS unit tests |
| [`macos-integration.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/macos-integration.yml) | push, dispatch | `self-hosted, macOS, ARM64, cardano-wallet` | macOS integration tests |

`windows.yml` and `windows-e2e.yml` span two platforms in one workflow: a Linux job cross-compiles
the binary and a Windows job then runs it. The dependency is structural — the artifact genuinely
comes from the other platform — so those workflows need both platforms to reach a conclusion, and a
repository serving only one of them gets no verdict from them. `release.yml` and `verify-release.yml`
are the same. They are exempted by name in `scripts/ci/check-workflow-platforms.sh`; nothing else may
acquire that coupling without the check failing.

`windows-2025-vs2026` is not a GitHub-hosted image. It is an organisation-specific runner, so a fork
cannot serve those jobs at any price without provisioning equivalent hardware.

### End-to-end

| Workflow | Trigger | Description |
|----------|---------|-------------|
| [`linux-e2e.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/linux-e2e.yml) | push, dispatch | Linux E2E tests against preprod |
| [`windows-e2e.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/windows-e2e.yml) | dispatch | Windows E2E tests (self-hosted) |

### Benchmarks & sync

| Workflow | Trigger | Description |
|----------|---------|-------------|
| [`linux-benchmarks.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/linux-benchmarks.yml) | push, dispatch | Restoration benchmarks on mainnet (long-running) |
| [`linux-mithril-sync.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/linux-mithril-sync.yml) | push, dispatch | Mithril snapshot sync test |

### Release

| Workflow | Trigger | Description |
|----------|---------|-------------|
| [`release.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/release.yml) | push, tags | Creates release candidate branches and release artifacts |
| [`publish.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/publish.yml) | push, tags, PR | Publishes documentation to GitHub Pages |

### Housekeeping

| Workflow | Trigger | Description |
|----------|---------|-------------|
| [`cleanup.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/cleanup.yml) | dispatch | Deletes old workflow runs |
| [`approve-docs.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/approve-docs.yml) | PR target | Auto-approves docs-only PRs |
| [`lean.yml`](https://github.com/cardano-foundation/cardano-wallet/actions/workflows/lean.yml) | push, PR | Lean specification checks (path-filtered to `specifications/`) |

## Benchmark History

The benchmark history pipeline (`benchmark-history.sh`) automatically aggregates performance data from recent CI runs to track regressions over time. It produces CSV data and SVG charts that are uploaded as workflow artifacts.

### Data collection

The pipeline follows these steps to gather data:
1. **Discovery**: Uses `gh run list` to find the last 6 months of successful `Linux Benchmarks` runs on the `master` branch.
2. **Download**: For each unique day with a successful run, it downloads the CSV artifacts from the following benchmark jobs:
   - API Benchmark
   - Latency Benchmark
   - DB Benchmark
   - Read-blocks Benchmark
   - Memory Benchmark
3. **Aggregation**: Combines the downloaded CSVs with the results from the current run.

### Checkpoint mechanism

To avoid downloading hundreds of historical runs in every CI session, the pipeline uses a **checkpoint** system:
- It attempts to download the `Benchmark History` artifact from the *most recent* successful run of the same workflow.
- If found, it uses the `benchmark-history.csv` from that artifact as a starting point (`--checkpoint`).
- Only runs newer than the checkpoint are downloaded and merged.

### Artifact retention

- **Historical data**: The aggregated `benchmark-history.csv` is the source of truth for all historical data.
- **Charts**: SVG charts are regenerated on every successful `master` run, providing a visual representation of performance trends for each benchmark category.
- **Retention**: GitHub Actions retains these artifacts according to the repository's retention policy (typically 90 days). The checkpoint mechanism ensures that data is preserved in the *latest* artifact even if the original individual run artifacts have expired.

## Nix verbosity

All `nix` commands in CI workflows must include the `--quiet` flag. This suppresses verbose build logs and warnings that clutter GitHub Actions output, making it easier to spot actual failures.

```yaml
# Good
nix build --quiet .#cardano-wallet
nix shell --quiet .#cardano-node -c cardano-node --version
nix develop --quiet --command scripts/check.sh

# Bad — missing --quiet
nix build .#cardano-wallet
nix build -L .#cardano-wallet
```

When adding or modifying workflow steps that invoke `nix`, always include `--quiet`.

## Self-hosted runners

Several workflows run on self-hosted machines. The GHA runner service replaces the former Buildkite agent on these machines.

### Windows machine

#### System configuration

We assume the machine is configured with a recent Windows version (2022 Server) and has winget installed.

* Install the [GitHub Actions runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners) as a Windows service
* Install the **Ruby** environment in version 2.7 using winget (needed for E2E tests):
  ```
  winget install RubyInstallerTeam.Ruby.2.7 --force --disable-interactivity  --accept-source-agreements --accept-package-agreements
  ```
* Install Ruby installer toolkit to be able to compile native extensions:
  ```
  ridk install
  ```
* Install some more packages:
  * `winget install zstandard` — decompressing hosted archives
  * `winget install nssm` — running cardano-node as a service

#### Runner configuration

* When launched as a service, the GHA runner runs as the [`Local System Account`](https://learn.microsoft.com/en-us/windows/win32/services/localsystem-account) which does not inherit the environment from the `hal` user. Ensure software installed through `winget` is on the runner's PATH.
* Configure environment secrets (`FIXTURE_DECRYPTION_KEY`, etc.) via the runner's `.env` file or repository/org-level GitHub Actions secrets.
* Ensure node DB files can be removed (they are created readonly which breaks `git clean -xfd`):
  ```
  icacls . /grant hal:F /T /Q
  ```
* Ensure `cardano-node` and `cardano-wallet` services are cleaned up after each run to avoid leaks from interrupted workflows.

#### Troubleshooting

Windows permissions are complex. Stick to the default `Local System Account` as the user for the runner service.

1. Ensure the user `SYSTEM` has full control to the runner work directory and this right is _inherited_:

   ```
   PS C:\actions-runner> icacls.exe .
   . NT AUTHORITY\SYSTEM:(OI)(CI)(F)
     BUILTIN\Administrators:(F)
     ZUR1-S-D-027\hal:(OI)(CI)(F)
   ```

2. To operate under the right identity, use [pstools](https://learn.microsoft.com/en-us/sysinternals/downloads/pstools):
   ```
   psexec -s -i cmd
   ```

3. If steps fail to delete the checkout directory, ensure no other process is locking it.

### macOS machine (hal-mac)

The macOS builder runs on a Mac Mini (Apple Silicon) managed via nix-darwin. Access via SSH through the jumpbox:

```bash
ssh mac-builder  # requires SSH config with ProxyJump through jumpbox-dev
```

#### Runner configuration

The GHA runner runs as a launchd service. Key paths:

- **Service plist**: `/Library/LaunchDaemons/org.nixos.github-runner-hal-mac.plist`
- **Runner directory**: `/var/lib/github-runner-hal-mac/`
- **Log file**: check via `journalctl` or the runner's `_diag/` directory

#### Updating the runner token

If the runner token expires or becomes invalid:

1. **Create a new runner token** at the repository's Settings > Actions > Runners page
2. **Update the token on the machine**:
   ```bash
   ssh mac-builder
   # Re-configure the runner with the new token
   ```
3. **Restart the runner**:
   ```bash
   sudo launchctl kickstart -k system/org.nixos.github-runner-hal-mac
   ```
4. **Verify the runner is connected** in the repository's Settings > Actions > Runners page

#### Environment variables

Secrets are configured via:

- `ATTIC_TOKEN` — from `/var/lib/gha-runner-hal-mac/env-attic-token`
- `FIXTURE_DECRYPTION_KEY` — from `/var/lib/gha-runner-hal-mac/env-fixture-decryption-key`
- `HAL_E2E_PREPROD_MNEMONICS` — from `/var/lib/gha-runner-hal-mac/env-hal-e2e-preprod-mnemonics`

#### Troubleshooting

- **Check runner status**: repository Settings > Actions > Runners
- **View logs**: check the runner's `_diag/` directory
- **Restart service**: `sudo launchctl kickstart -k system/org.nixos.github-runner-hal-mac`
- **Stop service**: `sudo launchctl stop system/org.nixos.github-runner-hal-mac`

##### Attic cache failures

The Attic cache job pushes build artifacts to the Attic cache server. If it fails:

1. **Check Attic token** — The JWT token in `/var/lib/gha-runner-hal-mac/env-attic-token` may have expired. Decode it:
   ```bash
   cat /var/lib/gha-runner-hal-mac/env-attic-token | cut -d. -f2 | base64 -d
   ```
   Look for the `exp` field (Unix timestamp).

2. **Test Attic login**:
   ```bash
   ATTIC_TOKEN=$(cat /var/lib/gha-runner-hal-mac/env-attic-token)
   nix-shell -p attic-client --run "attic login adrestia https://attic.cf-app.org/ $ATTIC_TOKEN"
   ```

3. **Verify Attic server** is reachable: `curl -I https://attic.cf-app.org/`

4. **SSL Certificate Error** — If you see `invalid peer certificate: UnknownIssuer`, the machine may be resolving `attic.cf-app.org` to an internal IP with an untrusted certificate.

   Check which IP is being used:
   ```bash
   ping -c1 attic.cf-app.org
   ```

   If it resolves to an internal IP (e.g., `10.1.21.x`), override with the external IP in `/etc/hosts`:
   ```bash
   sudo sed -i '' 's/ attic.cf-app.org//g; s/ attic//g' /etc/hosts
   echo "195.48.82.220 attic.cf-app.org" | sudo tee -a /etc/hosts
   ```

##### Stale processes

Test cluster processes (cardano-node) may accumulate if builds are interrupted:
```bash
ps aux | grep cardano-node
pkill -f "cardano-node.*test-cluster"
```
