# Research: Wallet Chain Continuity Recovery and Rescan Endpoint

**Branch**: `70004-resync-endpoint` | **Date**: 2026-09-01

## Q1: Where exactly does the chain continuity error propagate, and where is the right interception point?

**Decision**: Intercept at the `restoreWallet` level in `lib/wallet/src/Cardano/Wallet.hs`, not inside `restoreBlocks` itself.

**Rationale**: `restoreBlocks` runs inside an `atomically` block. The `fail` call there throws an `IOError` which propagates out through the `rollForward` callback and up through `chainSync`. Catching inside `atomically` is not straightforward and would require re-structuring the STM transaction. The correct fix is:

1. Replace the `fail` in `restoreBlocks` with a typed exception (`ErrChainNotContinuation`) so the catch site has a structured value to work with rather than a string-matched `IOError`.
2. In `restoreWallet`, wrap the `chainSync` call so that if `ErrChainNotContinuation` escapes, we:
   a. Call `rollbackBlocks` to the deepest available checkpoint.
   b. Retry `chainSync` once (the updated `readChainPoints = atomically listCheckpoints` will reflect the rolled-back state, so the node re-negotiates from the new tip).
   c. If the retry also throws `ErrChainNotContinuation`, log the unrecoverable error and halt cleanly.

**Alternatives considered**:
- Catching inside `restoreBlocks` itself: Rejected — `atomically` blocks cannot catch async exceptions and restructuring the STM transaction to return an `Either` would ripple through many call sites.
- Restarting the whole worker from the application layer: Rejected — the application layer has no visibility into why a worker died; the logic belongs in the wallet engine where the error originates.

---

## Q2: How does re-negotiation work after a rollback?

**Decision**: Re-negotiation is implicit. `chainSync` calls `readChainPoints` at the start of each connection to get the list of points the wallet can serve as intersection candidates. After `rollbackBlocks` runs, `listCheckpoints` returns a shorter list reflecting the rolled-back state. Restarting `chainSync` (by tail-calling it after the rollback) causes the chain sync mini-protocol to re-negotiate from those updated points.

**Rationale**: The existing infrastructure already supports this — `listCheckpoints` is a DB read of all persisted checkpoint slots, and the chain sync protocol negotiates the deepest common point between the node's chain and this list. No new plumbing is needed.

**Alternatives considered**:
- Manually signalling the intersection to the node: Rejected — the chain sync mini-protocol handles this automatically when given a new point list.

---

## Q3: Should the retry be immediate or include a delay?

**Decision**: Two-step retry with no delay. Step 1: roll back to the deepest checkpoint in the window and retry. Step 2 (if step 1 also fails): roll back to genesis and retry. If genesis rollback also fails, halt. No exponential backoff.

**Rationale**: Rolling back to genesis covers the full range of fork scenarios — any valid continuation from the node can be served after a genesis rollback, because genesis is always a common ancestor. The only case where genesis rollback fails is a genuinely wrong-network connection (mismatched genesis hash), which is a configuration error and should halt. Two attempts (checkpoint window + genesis) is sufficient to distinguish a recoverable fork from an unrecoverable misconfiguration, without introducing a retry loop.

**Alternatives considered**:
- Retry only once (to deepest checkpoint): Rejected — if the entire checkpoint window is deeper than the fork point, the wallet would halt unnecessarily and require a manual rescan when a genesis rollback would have recovered automatically.
- Retry indefinitely: Rejected — would create an infinite loop on unrecoverable states.
- Retry with delay: Rejected — unnecessary complexity; the node connection is already managed by the chain sync layer with its own reconnect logic.

---

## Q4: How should the rescan endpoint stop the running worker, clear DB state, and restart?

**Decision**: Use the existing `workerRegistry` / `withWorkerCtx` machinery. The handler:
1. Looks up the wallet in the registry (`withWorkerCtx`) — 404 if absent.
2. Checks whether a rescan is already in progress via an `IORef` or `TVar` in the worker context — 409 if true.
3. Signals the worker to stop (using the existing worker lifecycle API).
4. Runs the DB reset (rollback to genesis via `rollbackTo Origin` or equivalent).
5. Restarts the worker via the registry's restart mechanism.
6. Returns 202 immediately (all the above happens asynchronously after the initial checks).

**Rationale**: The 70002-shelley-multi-account prototype implemented a version of this. The key insight is that the rescan-in-progress flag must be checked before stopping the worker to avoid a race where two concurrent rescan requests both succeed. Using a `TVar Bool` in the worker state (set to `True` before stopping, cleared when the worker restarts and begins syncing) provides the necessary mutual exclusion.

**Alternatives considered**:
- Persisting rescan state to the DB: Rejected — the rescan status is transient; if the process is killed mid-rescan the wallet simply resumes from its last checkpoint on next startup (it does not need to re-start from genesis again).
- Using an application-level flag outside the worker: Rejected — the flag must be scoped to the wallet so that restarting the process clears it naturally.

---

## Q5: What DB operations constitute a "reset to genesis"?

**Decision**: Roll back to slot 0 / `Origin` using the existing `rollbackTo` DB primitive. This clears UTxO, transaction history, and delegation history via the existing delta-store machinery. Address discovery state reset requires an additional `resetAddressDiscovery` (or equivalent) call that resets gap counters and empties the discovered-address pool.

**Rationale**: `rollbackTo` already handles the UTxO/tx/delegation tables. Address discovery state is managed separately (it is part of the wallet's sequential/random discovery state, not the block-derived tables). Both operations must succeed atomically before the worker is restarted.

**Alternatives considered**:
- Deleting and recreating the SQLite file: Rejected — this is what wallet deletion/restore does; the rescan endpoint is explicitly designed to avoid losing key material.
- Separate per-table truncation: Rejected — would bypass the delta-store invariants and could leave the DB in an inconsistent state if the operation is interrupted.

---

## Q6: What logging should the automatic recovery emit?

**Decision**: A new `WalletWorkerLog` constructor `MsgChainContinuityRecovery` (structured, `Warning` severity) containing: wallet ID, stored checkpoint hash, incoming block hash, rollback target slot. A second constructor `MsgChainContinuityUnrecoverable` (`Error` severity) for the case where retry also fails.

**Rationale**: These are observable events that operators need to diagnose post-incident. Structured log fields allow log aggregation tools to filter and correlate. `Warning` for the recoverable case (it is self-healing), `Error` for the unrecoverable case (operator action required).

**Alternatives considered**:
- Logging as a plain string: Rejected — inconsistent with the rest of the wallet engine's structured logging pattern.
- Logging at `Debug` severity: Rejected — operators need visibility without enabling debug logging.
