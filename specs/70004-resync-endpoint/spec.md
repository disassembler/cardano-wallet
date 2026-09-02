# Feature Specification: Wallet Chain Continuity Recovery and Rescan Endpoint

**Feature Branch**: `70004-resync-endpoint`
**Created**: 2026-09-01
**Status**: Draft
**Input**: GitHub issue #5421 — restoreBlocks chain continuity crash + force rescan endpoint request

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Wallet Automatically Recovers from Chain Continuity Error (Priority: P1)

A wallet operator running cardano-wallet against a node restarts their node or switches to a different chain fork. The wallet's stored checkpoint no longer aligns with the chain the node presents. Currently this causes all wallet workers to die permanently and never restart, leaving wallets appearing healthy via the API while silently not syncing. After this fix, the wallet engine automatically detects the mismatch, rolls back its checkpoint to the last known good intersection, and resumes syncing without operator intervention.

**Why this priority**: This is the primary bug. The current behaviour causes silent data staleness with no user-visible indication. Wallets appear functional (200 OK on all endpoints) but stop tracking the chain entirely. This is the most severe failure mode.

**Independent Test**: Can be fully tested by injecting a chain continuity mismatch (e.g., providing blocks that don't follow from the stored checkpoint) and verifying the wallet worker does not crash, emits a structured warning log, rolls back, and resumes block application — delivering a self-healing wallet without any API call.

**Acceptance Scenarios**:

1. **Given** a wallet with a stored checkpoint at block N, **When** the chain sync protocol delivers a block whose parent does not match block N, **Then** the wallet engine rolls back to the deepest available checkpoint that is a valid ancestor of the presented chain and resumes syncing from that point without crashing the worker.
2. **Given** a wallet worker has detected and recovered from a chain continuity error, **When** the operator queries `GET /v2/wallets/{wid}`, **Then** the wallet's `state` reflects actual sync progress (not a stale pre-crash value).
3. **Given** a chain continuity error occurs, **When** the wallet engine rolls back and retries, **Then** a structured warning log entry is emitted containing the wallet ID, the stored checkpoint hash, the incoming block hash, and the rollback target — sufficient for an operator to diagnose the event without inspecting the database.
4. **Given** the rollback-and-retry also fails (the wallet DB has no valid ancestor intersection with the presented chain), **Then** the wallet engine logs a clear actionable error indicating the wallet requires a manual rescan, rather than silently dying or entering a crash loop.
5. **Given** multiple wallets share the same broken checkpoint state, **When** the engine recovers, **Then** each wallet recovers independently — one wallet's recovery does not block another's.

---

### User Story 2 - Wallet Operator Forces a Full Rescan via API (Priority: P2)

A wallet operator needs to force a specific wallet to re-index from genesis — either because automatic recovery could not find a valid intersection, the wallet DB state is believed to be corrupt, or new indexing logic requires replaying the chain. The operator calls a single API endpoint and the wallet begins rescanning without needing to delete and re-restore the wallet from its seed phrase.

**Why this priority**: This is the manual failsafe when automatic recovery is insufficient. It preserves the wallet's key material and settings while clearing only derived chain state. It is the explicit user-facing recovery path requested in the GitHub issue.

**Independent Test**: Can be fully tested by calling `POST /v2/wallets/{wid}/rescan` on a synced wallet and verifying the wallet's sync progress resets to 0%, the wallet resumes syncing from genesis, and balance/UTxO/transaction history is rebuilt correctly — without deleting and recreating the wallet.

**Acceptance Scenarios**:

1. **Given** a wallet exists and is fully synced, **When** the operator calls `POST /v2/wallets/{wid}/rescan`, **Then** the response is `202 Accepted` with an empty body, and subsequent `GET /v2/wallets/{wid}` calls show `state: syncing` with progress near 0%.
2. **Given** a wallet is currently rescanning, **When** the operator calls `POST /v2/wallets/{wid}/rescan` again, **Then** the response is `409 Conflict` and the in-progress rescan is not interrupted.
3. **Given** an unknown wallet ID is provided, **When** the operator calls `POST /v2/wallets/{wid}/rescan`, **Then** the response is `404 Not Found`.
4. **Given** a wallet's rescan completes, **When** the operator queries `GET /v2/wallets/{wid}`, **Then** the wallet's balance, UTxO set, and transaction history match what a fresh restore from the same seed phrase would produce.
5. **Given** a rescan is initiated, **When** the operator attempts to submit a transaction for that wallet during the rescan, **Then** an appropriate not-ready error is returned — the wallet is not silently dropped from `GET /v2/wallets`.

---

### User Story 3 - SQLite Connection Churn Eliminated After Worker Recovery (Priority: P3)

Before this fix, dead wallet workers cause every `GET /v2/wallets` or `GET /v2/wallets/{wid}` poll to hit the `whenNotResponding` path, which opens and closes multiple SQLite connections per wallet per request for the entire process lifetime. After this fix — either because workers no longer die (Story 1) or because a rescan restarts them (Story 2) — this connection churn does not occur during normal operation.

**Why this priority**: The churn is a secondary effect of the primary bug. It resolves automatically if Story 1 or Story 2 is implemented. It is called out explicitly because it produces observable symptoms (a log flood of "Closing single database connection" entries) that operators use to diagnose the primary failure.

**Independent Test**: Verifiable by confirming that after recovery, the rate of "Closing single database connection" log entries per API request returns to the baseline expected for a healthy wallet.

**Acceptance Scenarios**:

1. **Given** wallet workers have recovered (automatically or via rescan), **When** the operator polls `GET /v2/wallets` repeatedly, **Then** the "Closing single database connection" log entry rate matches the baseline for a healthy wallet (not the elevated rate observed when workers are dead).
2. **Given** a wallet is mid-rescan, **When** the operator polls `GET /v2/wallets/{wid}`, **Then** the response is served without opening excessive SQLite connections.

---

### Edge Cases

- What happens when no checkpoint in the rolling window is a valid ancestor, or `listCheckpoints` returns an empty list (wallet freshly created, not yet synced a single block)? The engine rolls back to genesis (`Origin`) and retries chain sync from there. If chain sync still fails after a genesis rollback, the engine halts with an actionable error (FR-005) — this indicates connecting to the wrong network, not a recoverable fork.
- What happens if `POST /v2/wallets/{wid}/rescan` is called while the wallet worker is mid-block-application? The rescan waits for the current atomic DB operation to complete before clearing state.
- What happens if the node disconnects mid-rescan? Rescan progress is preserved at the last committed checkpoint; the wallet resumes from there when the node reconnects (it does not restart from genesis again).
- What happens if the process is killed mid-rescan? On restart, the wallet resumes from its last committed checkpoint rather than restarting from genesis.
- What happens when a rescan is triggered for a wallet whose worker has already been killed by the chain continuity bug? The rescan must handle starting the worker from a stopped state, not just interrupting a running one.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The wallet engine MUST catch chain continuity errors from `restoreBlocks` without terminating the worker thread.
- **FR-002**: On catching a chain continuity error, the engine MUST roll the wallet's stored checkpoint back to the deepest available checkpoint that is a valid ancestor of the presented chain. If no checkpoint in the rolling window is a valid ancestor, the engine MUST roll back to genesis and restart from there.
- **FR-003**: After rollback (whether to a prior checkpoint or to genesis), the engine MUST re-initiate chain sync so the chain sync protocol re-negotiates the intersection with the node using the updated checkpoint list.
- **FR-004**: The engine MUST emit a structured warning log entry on each automatic rollback-and-retry, containing at minimum: wallet ID, stored checkpoint identifier, incoming block identifier, and rollback target identifier.
- **FR-005**: If rolling back to genesis and retrying chain sync also fails with a continuity error, the engine MUST log a clear actionable error and stop the worker cleanly — it MUST NOT enter an infinite crash-and-restart loop. (This case indicates a fundamental incompatibility such as connecting to the wrong network; a genesis rollback should resolve any valid fork scenario.)
- **FR-006**: The API MUST expose `POST /v2/wallets/{walletId}/rescan` accepting an empty JSON body (`{}`), requiring no passphrase.
- **FR-007**: `POST /v2/wallets/{walletId}/rescan` MUST respond `202 Accepted` immediately and perform the rescan asynchronously.
- **FR-008**: On rescan initiation, the wallet's stored UTxO set, transaction history, and delegation history MUST be cleared; address discovery pools MUST be reset to their initial state with the wallet's configured gap limit.
- **FR-009**: The wallet worker MUST restart automatically after rescan state is cleared, resuming chain following from genesis.
- **FR-010**: `POST /v2/wallets/{walletId}/rescan` MUST return `409 Conflict` if a rescan is already in progress for that wallet.
- **FR-011**: `POST /v2/wallets/{walletId}/rescan` MUST return `404 Not Found` if the wallet ID does not exist.
- **FR-012**: During a rescan, `GET /v2/wallets/{wid}` MUST report `state: { status: "syncing", progress: { quantity: N, unit: "percent" } }` reflecting the rescan's actual chain progress.
- **FR-013**: While a rescan is in progress for a wallet, any request that requires a live wallet worker (e.g. transaction construction or submission) MUST return a clear not-ready error — the wallet MUST continue to appear in `GET /v2/wallets` and MUST NOT be silently dropped.

### Key Entities

- **Wallet Checkpoint**: A point in the wallet's sync history (block hash + slot) used as a rollback target. The wallet maintains a rolling window of checkpoints; the deepest available one is used for automatic recovery.
- **Wallet Worker**: The per-wallet background thread responsible for applying blocks and updating derived state (UTxO, transactions, addresses). Each wallet has exactly one worker.
- **Chain Continuity Error**: The error raised when the first block delivered by the node does not follow from the wallet's current checkpoint (their parent-child relationship is broken).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A wallet that previously crashed permanently on chain continuity error recovers and resumes syncing within one chain sync reconnect cycle — without any operator intervention.
- **SC-002**: After automatic recovery, `GET /v2/wallets/{wid}` reflects live sync progress within 60 seconds of the recovery event.
- **SC-003**: `POST /v2/wallets/{wid}/rescan` returns `202 Accepted` within 1 second of the request being received, regardless of wallet size or sync history length.
- **SC-004**: A wallet that completes a full rescan from genesis reaches the same balance, UTxO set, and transaction history as a wallet freshly restored from the same seed phrase against the same chain.
- **SC-005**: The "Closing single database connection" log entry rate during normal post-recovery operation matches the baseline for a healthy wallet: at most 1 such entry per `GET /v2/wallets/{wid}` request (the normal connection close after a successful DB read), compared to the 7+ entries per request observed when workers are dead.
- **SC-006**: No wallet worker enters an infinite restart loop on a genuinely unrecoverable chain continuity error — the worker halts with a logged actionable error after at most two retry attempts (checkpoint-window rollback + genesis rollback).

## Assumptions

- Automatic recovery rolls back as far as needed, up to and including genesis, before retrying chain sync. This means a wallet may perform a full implicit rescan (from genesis) without any operator action if no checkpoint in the rolling window matches the presented chain.
- Automatic rollback-and-retry is attempted in two steps: (1) roll back to deepest available checkpoint in the window and retry; if that also fails, (2) roll back to genesis and retry. If genesis rollback also fails, the worker halts. No exponential backoff or further retry is implemented — two attempts is sufficient to distinguish a fork (recoverable) from a wrong-network connection (not recoverable).
- The explicit rescan endpoint (`POST /v2/wallets/{wid}/rescan`) is distinct from automatic recovery. It is intended for power-user use, future data migrations requiring history replay, or bug scenarios not covered by the automatic path.
- The rescan endpoint clears derived state only (UTxO, transactions, delegation, address discovery state). Key material (root private key, mnemonic fingerprint) and wallet metadata (name, passphrase hash, gap limit) are preserved.
- The prototype implementation in `70002-shelley-multi-account` (the `POST /v2/wallets/{wid}/rescan` handler and its DB-layer operations) is used as the starting point for Part 2 and cherry-picked or rebased into this branch.
- Byron wallets are in scope for the rescan endpoint at the DB-layer reset level, but automatic chain continuity recovery testing targets Shelley-and-later wallets where the issue was observed.
