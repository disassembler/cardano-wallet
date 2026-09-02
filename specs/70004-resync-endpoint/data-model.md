# Data Model: Wallet Chain Continuity Recovery and Rescan Endpoint

**Branch**: `70004-resync-endpoint` | **Date**: 2026-09-01

## Overview

This feature introduces no new persistent data structures. It modifies error-handling behaviour in the wallet engine (Part 1) and adds a transient in-memory state flag to the worker context (Part 2). All persistent state is managed through the existing delta-store / `DBLayer` abstractions.

---

## Existing Entities (unchanged structure, modified interactions)

### Wallet Checkpoint

Represents a committed point in the wallet's sync history. Stored persistently in SQLite via the delta-store.

| Field | Type | Description |
|-------|------|-------------|
| slot | `SlotNo` | The slot number of this checkpoint |
| blockHash | `Hash "BlockHeader"` | The block header hash at this slot |
| walletState | `Wallet s` | The full wallet state snapshot (UTxO, discovery state) at this point |

**Relevant operations**:
- `listCheckpoints :: STM [ChainPoint]` — returns all persisted checkpoint slots, ordered oldest-to-newest. Used by `readChainPoints` to negotiate intersection with the node.
- `rollbackTo :: ChainPoint -> STM ()` — rolls back all derived state (UTxO, transactions, delegations) to the given slot, discarding newer checkpoints.

**Recovery interaction**: After catching `ErrChainNotContinuation`, the engine calls `listCheckpoints` to get the current checkpoint list, selects the deepest one as the rollback target, and calls `rollbackTo` with that point. The updated checkpoint list is then used by the restarted `chainSync` for re-negotiation.

**Rescan interaction**: Rescan calls `rollbackTo Origin` (slot 0), which clears all derived state. Address discovery state is reset separately (see below).

---

### Address Discovery State

Part of the `Wallet s` snapshot stored at each checkpoint. Tracks which addresses have been discovered and the current gap position for sequential wallets, or the set of known addresses for random wallets.

**Rescan interaction**: After `rollbackTo Origin`, the address discovery state embedded in the genesis checkpoint is the initial empty state. No separate operation is needed beyond the rollback, provided the genesis checkpoint is re-inserted with an empty discovery state.

*Note*: If the wallet's genesis checkpoint itself was stored with a non-empty discovery state (e.g., from import with pre-known addresses), rescan preserves that initial discovery state — it resets to genesis, not to factory-blank.

---

## New Transient State (in-memory only, not persisted)

### RescanStatus (per-wallet, in worker context)

Tracks whether a rescan is currently in progress for a wallet. This flag is held in the worker registry's per-wallet context and is cleared when the worker restarts after rescan or when the process restarts.

| Field | Type | Description |
|-------|------|-------------|
| isRescanning | `TVar Bool` | `True` while the stop-reset-restart sequence is in progress |

**Lifecycle**:
1. `False` on normal wallet startup.
2. Set to `True` atomically when `POST /v2/wallets/{wid}/rescan` begins.
3. Checked (still `True`) → `409 Conflict` on duplicate rescan requests.
4. Cleared to `False` when the restarted worker successfully begins applying blocks.

**Why not persisted**: If the process is killed mid-rescan the wallet resumes from its last committed checkpoint on restart. The `isRescanning` flag is a guard against concurrent API calls within a single process lifetime, not a durable state machine.

---

## New Error Types

### ErrChainNotContinuation

A typed Haskell exception replacing the current `fail` call in `restoreBlocks`.

```
data ErrChainNotContinuation = ErrChainNotContinuation
    { storedTip   :: BlockHeader   -- the wallet's current checkpoint
    , incomingBlock :: BlockHeader  -- the block the node presented
    }
```

**Thrown by**: `restoreBlocks` when `cp0 `isParentOf` firstHeader blocks` is `False`.
**Caught by**: `restoreWallet` (once; triggers rollback-and-retry).

### ErrRescanAlreadyRunning

The error type returned as `409 Conflict` when `POST /v2/wallets/{wid}/rescan` is called while a rescan is already in progress.

```
newtype ErrRescanAlreadyRunning = ErrRescanAlreadyRunning WalletId
```

---

## State Transitions

### Wallet Worker State Machine (extended)

```
         ┌─────────────────────────────────────┐
         │           STARTING                  │
         └──────────────┬──────────────────────┘
                        │ worker thread launched
                        ▼
         ┌─────────────────────────────────────┐
    ┌───▶│           SYNCING                   │◀──────────────────┐
    │    └──────────────┬──────────────────────┘                   │
    │                   │                                           │
    │          chain continuity error                      rescan complete
    │                   ▼                                           │
    │    ┌─────────────────────────────────────┐                   │
    │    │     RECOVERING (auto-rollback)       │                   │
    │    └──────────────┬──────────────────────┘                   │
    │                   │                                           │
    │         retry succeeds ────────────────────────────────────►─┘
    │                   │
    │         retry fails
    │                   ▼
    │    ┌─────────────────────────────────────┐
    │    │       DEAD (log error, halt)         │
    │    └──────────────┬──────────────────────┘
    │                   │
    │    POST /rescan called (from DEAD or SYNCING)
    │                   ▼
    │    ┌─────────────────────────────────────┐
    │    │        RESCANNING                   │
    │    │    (isRescanning TVar = True)        │
    │    └──────────────┬──────────────────────┘
    │                   │ DB reset complete, worker restarted
    └───────────────────┘
```
