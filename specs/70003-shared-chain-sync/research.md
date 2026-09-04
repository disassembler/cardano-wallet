# Research: Shared Master Chain Sync

## Finding 1: Broadcast primitive

**Decision**: `TBQueue` per subscriber (one per wallet), not `TChan`.

**Rationale**: `TChan` broadcast has O(subscribers × unread-messages) memory growth. `TBQueue` per subscriber gives independent flow control and back-pressure. A bounded capacity (~16 blocks) means a slow wallet processes its queue while fast wallets stay current — no global stall. Already used in `newTBQueueBuffer` in `Streaming.hs`.

**Alternatives considered**: `TChan`/`TBChan` — rejected due to shared memory growth and inability to bound per-subscriber lag independently.

## Finding 2: "Reached tip" detection

**Decision**: Distance-based heuristic. The master thread's `rollForward` receives `ChainTip` alongside each block batch. When `tipDistance blockNo nodeTip <= 1`, the thread is at tip. Catch-up threads use the same condition to detect handoff readiness.

**Rationale**: The Ouroboros ChainSync protocol has no explicit "at tip" message surfaced through `ChainFollower`. The `distance <= 1` condition — where `chainSyncWithBlocks` switches from pipelined to `oneByOne` — is the canonical in-codebase signal. `MsgTipDistance` is already traced at Debug level confirming intent.

**Alternatives considered**: `SyncProgress` from `withFollowStatsMonitoring` — requires time interpreter and slot-to-time conversion; distance check is simpler and has no external dependencies.

## Finding 3: Master thread `readChainPoints`

**Decision**: Collect the union of all registered wallets' checkpoints (oldest-first). The Ouroboros intersection negotiation then finds the oldest common point, ensuring no wallet misses blocks.

**Rationale**: If any wallet is behind, the master must start from that wallet's last checkpoint. Starting from the minimum is always correct. Wallets ahead of the start point skip blocks before their own tip via per-wallet checkpoint tracking.

**Alternatives considered**: Always start from `Origin` — correct but wastes bandwidth replaying all history for already-synced wallets every restart.

## Finding 4: Rollback fan-out

**Decision**: Broadcaster's `rollBackward` acquires a write lock on the subscriber registry, writes `Rollback point` to each wallet's `TBQueue`, collects actual rollback points (each wallet may roll to a different nearest checkpoint), returns the minimum to the node.

**Rationale**: `rollbackTo_` in the DB layer is already `atomically` (STM). Per-wallet rollbacks can be concurrent but the node needs one answer — the minimum across all wallets is conservative and always correct. Rollbacks are rare so serialization cost is negligible.

**Alternatives considered**: Concurrent fan-out with `mapConcurrently` — possible, but the reduction step (min across actual points) is still sequential and rollbacks are infrequent enough that full serialization is acceptable.

## Finding 5: Rescan endpoint scope

**Decision**: `POST /v2/wallets/{wid}/rescan` operates at the wallet level (all accounts). An `?all=true` global variant stops the master sync thread, resets all wallets simultaneously, and restarts as a single coordinated catch-up. Per-account rescan is deferred to the 70002 branch.

**Rationale**: Wallet-level rescan covers the corruption recovery use case. The global `?all=true` variant covers the "new feature adds data we didn't originally track" use case — e.g., a software upgrade that begins tracking new fields requires a full re-index of all wallets. Stopping the master thread during global resync ensures consistency (no partial updates while resetting).

**Alternatives considered**: Per-account rescan in this branch — deferred because account-level UTxO plumbing lives in 70002-shelley-multi-account.

## Finding 6: Catch-up thread node connection

**Decision**: Each catch-up thread opens its own `chainSync` connection via `NetworkLayer`. When catch-up completes, the connection is closed and the thread exits.

**Rationale**: Sharing the master's connection would require multiplexing historical and live blocks on one Ouroboros ChainSync connection, which the protocol does not support. Separate connections are clean and the node accepts multiple simultaneous Node-to-Client connections.

**Alternatives considered**: Replay from stored transaction history (no second node connection) — requires the DB to hold a complete transaction history for all blocks, which is not guaranteed (pruning applies).

## Finding 7: Streaming.hs as foundation

**Decision**: Extend `Streaming.hs` to export the `Message` type for reuse in `Broadcasting.hs`. The `withStreamingFromBlockChain` pattern (background `async` + `TBQueue` consumer loop) is the direct template for the broadcaster.

**Rationale**: `Streaming.hs` already solves the "ChainFollower → buffered stream" problem. The broadcaster is the "one stream → N buffered sinks" extension. Sharing `Message a = Forward ChainTip a | Rollback ChainPoint` avoids type duplication.

## Finding 8: ApiLayer holds the broadcaster

**Decision**: `ApiLayer s` gains a `ChainBroadcaster IO (CardanoBlock StandardCrypto)` field. Workers subscribe at registration time and unsubscribe at deletion time.

**Rationale**: `ApiLayer` already holds the `NetworkLayer`, `WorkerRegistry`, and `DBFactory`. The broadcaster is a natural peer — it is created once at startup alongside the master thread and lives for the duration of the service.
