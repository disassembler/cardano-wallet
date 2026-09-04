# Implementation Plan: Shared Master Chain Sync

**Branch**: `70003-shared-chain-sync` | **Date**: 2026-08-25 | **Spec**: [spec.md](spec.md)

## Summary

Replace the current one-chain-sync-connection-per-wallet model with a single master sync thread that fans block and rollback events out to all registered wallet states via STM, while individual catch-up threads handle new-wallet historical sync independently. The change is entirely transparent to existing API clients — no endpoint schemas change. The only new public surface is a rescan endpoint (`POST /v2/wallets/{wid}/rescan`) that resets a wallet to genesis for corruption recovery.

## Technical Context

**Language/Version**: Haskell GHC 9.12.3
**Primary Dependencies**: `ouroboros-network` (ChainSync mini-protocol), `io-classes` (STM/async), `cardano-wallet-network-layer`, `cardano-wallet-wallet`
**Storage**: SQLite via `cardano-wallet-wallet` delta store (`DBVar`)
**Testing**: `tasty`/`hspec` unit tests, `cardano-wallet-integration` integration tests against local cluster
**Target Platform**: Linux (primary), Windows and macOS (cross-compiled)
**Project Type**: Internal library refactor + one new REST endpoint
**Performance Goals**: At tip, N wallets consume the same node bandwidth as 1 wallet (O(1) connections). Catch-up throughput ≥ current per-wallet throughput (pipelining preserved).
**Constraints**: Zero breaking changes to existing API. No observable behavioral change for existing clients. Rollback fan-out must be serialized correctly.
**Scale/Scope**: Targets all Shelley sequential wallets. Byron and Shared wallets out of scope for v1.

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Maintenance-First Stability | ✓ PASS | Transparent refactor; existing tests must stay green. Rollback coordination is the highest-risk area — requires careful property testing. |
| II. Era-Aware Design | ✓ PASS | `fromCardanoBlock` era dispatch is unchanged; the broadcaster layer operates above era boundaries. |
| III. Type Safety as Security | ✓ PASS | New `ChainBroadcaster` type carries phantom type parameters matching existing `ChainFollower`. No unsafe coercions. |
| IV. Formal Specification | ✓ PASS | No API schema changes. Swagger unchanged except for new rescan endpoint. |
| V. Reproducible Builds | ✓ PASS | No new external dependencies. All primitives (`TBQueue`, `async`, `STM`) are already in the dependency graph. |
| VI. Comprehensive Testing | ✓ PASS | Requires new unit tests for broadcaster fan-out and rollback coordination, plus integration test for rescan endpoint. |
| VII. Code Quality Gates | ✓ PASS | Fourmolu, HLint, `-Wall`/`-Werror` apply as always. |

## Project Structure

### Documentation (this feature)

```text
specs/70003-shared-chain-sync/
├── plan.md              ← this file
├── research.md
├── data-model.md
├── contracts/
│   └── rescan-endpoint.md
└── tasks.md
```

### Source Code Layout

The refactor spans three existing packages. No new packages are created.

```text
lib/network-layer/src/Cardano/Wallet/Network/
├── Streaming.hs            ← EXTEND: add multi-subscriber broadcast
└── Broadcasting.hs         ← NEW: ChainBroadcaster, subscriber registry, handoff logic

lib/wallet/src/Cardano/Wallet/
├── Registry.hs             ← MODIFY: workers subscribe to broadcaster instead of owning chainSync
└── Wallet.hs               ← MODIFY: restoreWallet takes broadcaster subscription; new catchUpWallet

lib/api/src/Cardano/Wallet/Api/
├── Http/Shelley/Server.hs  ← ADD: rescanWalletH handler
└── Http/Server.hs          ← WIRE: rescanWalletH into wallet routes

lib/api/src/Cardano/Wallet/
└── Api.hs                  ← ADD: RescanWallet API type
```

## Phase 0: Research

### Resolved Decisions

**Decision 1: Broadcast primitive — `TBQueue` per subscriber, not `TChan`**
- Decision: Each subscriber (wallet) gets its own `TBQueue (Message blocks)`. The broadcaster iterates the registry and `writeTBQueue`s to each.
- Rationale: `TChan`/`TBChan` has O(subscribers) memory growth per unread message across all readers. `TBQueue` per subscriber gives each wallet independent flow control and back-pressure. The existing `newTBQueueBuffer` in `Streaming.hs` already uses this pattern. Bounded queues (capacity ~16 blocks) prevent one slow wallet from stalling others — slow wallets drop to processing their queue while fast wallets stay current.
- Alternatives considered: `TChan` broadcast (all subscribers share one write end) — rejected due to memory growth and inability to bound per-subscriber lag independently.

**Decision 2: "Reached tip" detection — distance-based heuristic in the broadcaster**
- Decision: The master thread's `rollForward` callback receives the node tip alongside each block batch. When `tipDistance blockNo nodeTip <= 1`, the master is at tip. Catch-up threads independently observe their own tip distance. A catch-up thread signals "handoff ready" by writing a sentinel to a shared `TMVar` when its own distance hits 0.
- Rationale: The Ouroboros ChainSync protocol has no explicit "you are at tip" message surfaced to `ChainFollower`. The `distance <= 1` condition (where the client switches from pipelined to `oneByOne` mode) is the canonical in-codebase definition of "at tip." `MsgTipDistance` is already traced at Debug level, confirming this is the intended signal.
- Alternatives considered: Using `SyncProgress` from `withFollowStatsMonitoring` — this uses the time interpreter and requires a slot-to-time conversion; the distance check is simpler and doesn't depend on the time interpreter.

**Decision 3: `readChainPoints` for the master thread — intersection of all wallet checkpoints**
- Decision: The master thread's `readChainPoints` returns the union of all registered wallets' checkpoints, sorted oldest-first. The node intersection negotiation will find the oldest common point across all wallets, ensuring no wallet misses blocks.
- Rationale: If any wallet is behind, the master must start from that wallet's last checkpoint, not from tip. Starting from the minimum ensures correctness. Wallets that are already ahead will ignore blocks before their own tip (via per-wallet checkpoint tracking).
- Alternatives considered: Starting always from origin (simplest, but wastes bandwidth re-replaying all history for already-synced wallets).

**Decision 4: Rollback fan-out serialization**
- Decision: The broadcaster's `rollBackward` callback acquires a write lock on the subscriber registry before calling each wallet's `rollbackBlocks`. Each wallet rolls back independently (may land at different actual checkpoints). The broadcaster collects all actual rollback points and returns the minimum (oldest) to the node, which triggers re-negotiation if needed.
- Rationale: `rollbackTo_` is already `atomically` (STM), so per-wallet rollbacks can be executed concurrently in principle. However, the return value matters for the Ouroboros protocol — the node needs to know the actual point to resume from. Taking the minimum across all wallets is conservative and always correct.
- Alternatives considered: Concurrent fan-out rollback with `mapConcurrently` — possible but the node only accepts one answer; serializing is simpler and rollbacks are rare.

**Decision 5: Rescan endpoint — wallet-level, not account-level (for this branch)**
- Decision: `POST /v2/wallets/{wid}/rescan` resets the entire wallet (account 0H and all extra accounts) to genesis and starts a catch-up. Per-account rescan is deferred to the 70002-shelley-multi-account branch which will rebase on top of this.
- Rationale: The shared chain sync architecture enables per-account rescan, but the account-level plumbing (per-account UTxO, per-account SeqState in the broadcaster's address map) lives in the multi-account branch. This branch only introduces the infrastructure.

**Decision 6: Catch-up thread — separate node connection, no sharing with master**
- Decision: Each catch-up thread opens its own `chainSync` connection via the existing `NetworkLayer`. When the thread finishes catch-up, it closes the connection and unregisters from the catch-up registry. The master thread does not slow down or pause during catch-up.
- Rationale: Sharing the master's connection would require multiplexing historical block requests and tip blocks, which the Ouroboros ChainSync protocol does not support on one connection. Separate connections are simpler and node allows multiple simultaneous connections.

## Phase 1: Design

### Data Model

See [data-model.md](data-model.md).

### API Contract

See [contracts/rescan-endpoint.md](contracts/rescan-endpoint.md).

### Architecture Walkthrough

#### At-tip path (master thread)

```
NetworkLayer.chainSync ──► ChainBroadcaster.rollForward
                               │
                               ├──► wallet A: writeTBQueue qA (Forward tip blocks)
                               ├──► wallet B: writeTBQueue qB (Forward tip blocks)
                               └──► wallet C: writeTBQueue qC (Forward tip blocks)

Per-wallet consumer thread (one per wallet):
  readTBQueue q ──► restoreBlocks walletCtx blocks tip
```

#### Catch-up path (new wallet or rescan)

```
catchUpWallet wid ──► chainSync (new connection, from wallet's last checkpoint)
                          │
                          ├──► restoreBlocks walletCtx blocks tip  [historical blocks]
                          │
                          └──► when tipDistance <= 1:
                                  register wid in broadcaster's address map
                                  subscribe wid's TBQueue to broadcaster
                                  close catch-up connection
                                  exit thread
```

#### Rollback path

```
ChainBroadcaster.rollBackward point
    │
    ├──► acquire broadcaster write lock
    ├──► for each subscriber: writeTBQueue q (Rollback point)
    │       per-wallet consumer: rollbackBlocks walletCtx (toSlot point)
    └──► return min(actual rollback points)
```

#### Rescan path

```
POST /v2/wallets/{wid}/rescan
    │
    ├──► unsubscribe wid from broadcaster (stop receiving tip blocks)
    ├──► rollbackBlocks walletCtx Origin   (clear UTxO/tx history in DB)
    ├──► reset SeqState discovery pools in DB
    └──► start catchUpWallet wid thread    (fresh sync from genesis)
         returns 202 Accepted immediately
```

### Key Types (Haskell — actual implementation)

```haskell
-- lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs

-- Per-subscriber state; replaces the planned 'Subscriber' type
data SubscriberState k = SubscriberState
    { ssOps          :: WalletBroadcastOps   -- callbacks into Wallet.hs
    , ssForwardQueue :: TQueue (NonEmpty Block, ChainTip)
    , ssRollbackQueue :: TQueue ...
    , ssThread       :: Async ()
    , ssActive       :: TVar Bool            -- set True after drain-before-activate
    }

data ChainBroadcaster k = ChainBroadcaster
    { bcSubscribers    :: TVar (Map k (SubscriberState k))
    , bcCurrentTip     :: TVar ChainTip
    , bcCatchUpSet     :: TVar (Set k)
    , bcAddressIndex   :: TVar (Map Address k)   -- shared address → wallet routing
    , bcUTxOIndex      :: TVar (Map TxIn k)      -- shared UTxO → wallet routing
    , bcCatchUpSemaphore :: QSem                  -- limits concurrent catch-up threads
    }

-- Queues are unbounded TQueue (not TBQueue); back-pressure via bcCatchUpSemaphore

broadcasterFollower
    :: ChainBroadcaster k
    -> ChainFollower IO ChainPoint ChainTip blocks

-- Returns (masterBlockNo, activeFlag, forwardQueue) for drain-before-activate protocol
subscribe
    :: ChainBroadcaster k
    -> k
    -> WalletBroadcastOps
    -> IO (Maybe BlockNo, TVar Bool, TQueue (NonEmpty Block, ChainTip))

unsubscribe
    :: ChainBroadcaster k
    -> k
    -> IO ()

-- lib/wallet/src/Cardano/Wallet.hs

-- Exported callbacks from wallet layer into broadcaster
data WalletBroadcastOps = WalletBroadcastOps { ... }

mkWalletBroadcastOps :: WalletLayer IO s -> WalletBroadcastOps

-- Catch-up: sync from last checkpoint to tip, then hand off to broadcaster.
-- Contains nested helpers activateWithDrain and monitorAndRestartConsumer.
catchUpWallet
    :: NetworkLayer IO block
    -> WalletLayer IO s
    -> ChainBroadcaster WalletId
    -> WalletId
    -> IO ()
```

> **Implementation divergences from original pseudocode**:
> - `TBQueue` → `TQueue` (unbounded); concurrency controlled by `bcCatchUpSemaphore :: QSem`
> - `Subscriber` → `SubscriberState` (richer: tracks thread, active flag, separate queues)
> - `subscribe` returns `IO (Maybe BlockNo, TVar Bool, TQueue ...)` rather than `STM ()` — enables drain-before-activate (caller drains stale queue entries before setting `ssActive = True`)
> - Address-level routing added as `bcAddressIndex` / `bcUTxOIndex` rather than per-block full-wallet dispatch
> - `walletSyncConsumer` not present; replaced by `activateWithDrain` + `monitorAndRestartConsumer` inside `catchUpWallet`
> - `Registry.hs` not modified; subscription wired through `Wallet.hs` + `ApiLayer` directly

### Implementation Phases

**Phase 1 — Broadcasting infrastructure** (no behavior change yet)
- Implement `ChainBroadcaster` and `Broadcasting.hs`
- Unit test: fan-out to N subscribers, rollback coordination, slow subscriber back-pressure

**Phase 2 — Wire master thread into ApiLayer**
- Replace per-wallet `chainSync` calls in `registerWorker` with subscriber registration
- `ApiLayer` holds one `ChainBroadcaster`; wallet workers subscribe their `TBQueue`
- Integration test: 3 wallets, verify single node connection, all balances correct

**Phase 3 — Catch-up threads**
- Implement `catchUpWallet` with tip-detection and handoff
- Wire into `createWalletWorker` (new wallet starts catch-up then hands off)
- Integration test: add wallet to running instance, observe catch-up → handoff

**Phase 4 — Rescan endpoints**
- Add `POST /v2/wallets/{wid}/rescan` — single wallet reset to genesis, async 202
- Add `POST /v2/wallets/resync` — global resync: stop master thread, reset all wallets, shared catch-up, resume master
- Wire both into Shelley Server handlers
- Integration test: single-wallet rescan verifies correct balance; global resync verifies all wallets recover

### Files Changed

| File | Change |
|------|--------|
| `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs` | NEW — `ChainBroadcaster`, `SubscriberState`, `subscribe`, `unsubscribe`, `broadcasterFollower`, `runMasterSync`; adds `bcAddressIndex`, `bcUTxOIndex`, `bcCatchUpSemaphore` |
| `lib/network-layer/src/Cardano/Wallet/Network/Streaming.hs` | EXTEND — expose `Message` type for `Broadcasting.hs` |
| `lib/wallet/src/Cardano/Wallet.hs` | ADD `catchUpWallet` (with nested `activateWithDrain`, `monitorAndRestartConsumer`), `mkWalletBroadcastOps`, `WalletBroadcastOps`; imports `ChainBroadcaster (..)`, `SubscriberState (..)`, `waitCatch`, `QSem`, `IORef`, `Map` |
| `lib/api/src/Cardano/Wallet/Api.hs` | ADD `PostWalletRescan` API type; ADD `_chainBroadcaster :: ChainBroadcaster WalletId` field to `ApiLayer` |
| `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` | ADD `postWalletRescan` handler; initialize broadcaster and start master sync thread in `newApiLayer` |
| `lib/api/src/Cardano/Wallet/Api/Http/Server.hs` | WIRE `postWalletRescan` into wallet routes |
| `lib/api/src/Cardano/Wallet/Api/Link.hs` | ADD rescan link helpers |
| `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs` | NEW — integration tests `CHAIN_SYNC_01`–`CHAIN_SYNC_03` |
| `lib/benchmarks/exe/chain-sync-flood-bench.hs` | NEW — `chain-sync-flood-bench`; `observerCounts = [1, 5, 10, 20, 50]`; `catchUpConcurrency = 1000` |
| `lib/wallet/src/Cardano/Wallet/Registry.hs` | **NOT modified** — subscription wired through `Wallet.hs` + `ApiLayer` directly |
| `specifications/api/swagger.yaml` | ADD `POST /v2/wallets/{walletId}/rescan` endpoint definition |
