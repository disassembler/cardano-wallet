# Data Model: Shared Master Chain Sync

## New In-Memory Entities

### ChainBroadcaster

Lives in `ApiLayer`. Created once at service startup. Never persisted.

| Field | Type | Description |
|-------|------|-------------|
| `bcSubscribers` | `TVar (Map SubscriberId (Subscriber IO blocks))` | All wallets currently subscribed to tip blocks |
| `bcCurrentTip` | `TVar ChainTip` | Last tip seen by the master thread; used by catch-up threads to detect handoff readiness |
| `bcCatchUpSet` | `TVar (Set WalletId)` | Wallets currently in catch-up (excluded from master fan-out) |

**State transitions**:
- `Empty` → `Running`: on service startup, master thread starts and broadcaster is initialized
- `Running` + `subscribe`: wallet transitions from catch-up to live updates
- `Running` + `unsubscribe`: wallet deleted or rescan triggered
- `Running` → `Suspended`: global resync requested (all wallets unsubscribed, master thread paused)
- `Suspended` → `Running`: global resync catch-up completes, master thread resumes

### Subscriber

One per wallet. Lives inside `ChainBroadcaster.bcSubscribers`. Never persisted.

| Field | Type | Description |
|-------|------|-------------|
| `subQueue` | `TBQueue (Message blocks)` | Bounded queue of blocks/rollbacks for this wallet; capacity ~16 |
| `subRollback` | `Slot -> IO ChainPoint` | This wallet's `rollbackBlocks` function; called by broadcaster during rollback fan-out |
| `subWalletId` | `WalletId` | Identity for registry lookup |

### CatchUpThread

Transient — exists only while a wallet is catching up. Not persisted.

| Field | Type | Description |
|-------|------|-------------|
| `cutWalletId` | `WalletId` | Which wallet is catching up |
| `cutThread` | `Async ()` | The async thread handle; cancelled on rescan/delete |
| `cutHandoff` | `TMVar ()` | Written by catch-up thread when `tipDistance <= 1`; master reads to confirm handoff |

## Modified In-Memory Entities

### ApiLayer (extended)

Gains two new fields:

| Field | Type | Description |
|-------|------|-------------|
| `_chainBroadcaster` | `ChainBroadcaster IO (CardanoBlock StandardCrypto)` | The shared broadcaster |
| `_catchUpRegistry` | `TVar (Map WalletId (Async ()))` | Active catch-up threads, for cancellation on delete/rescan |

## Persistent State Changes

**No schema changes.** The DB schema is unchanged. Catch-up progress is implicitly stored via the existing wallet checkpoint mechanism — if the service restarts mid-catch-up, the wallet's last checkpoint is read from the DB and catch-up resumes from there (not from genesis).

## Message Protocol (in-process only)

```
Message blocks
    = Forward ChainTip (NonEmpty blocks)   -- new blocks at tip
    | Rollback ChainPoint                  -- roll back to this point
```

This type is already defined in `Streaming.hs` and will be exported for use in `Broadcasting.hs`.

## Rescan State Transitions

### Single-wallet rescan (`POST /v2/wallets/{wid}/rescan`)

```
Wallet state:  Live (subscribed to broadcaster)
     │
     ▼  rescan triggered
Wallet state:  Unsubscribed (removed from bcSubscribers)
     │         DB rolled back to genesis
     │         SeqState discovery pools reset
     ▼  catch-up thread started
Wallet state:  CatchingUp (in bcCatchUpSet)
     │
     ▼  tipDistance <= 1
Wallet state:  Live (re-subscribed to broadcaster)
```

### Global resync (`POST /v2/wallets/resync` or `POST /v2/wallets/{wid}/rescan?all=true`)

```
All wallets:   Live
     │
     ▼  global resync triggered
Master thread: Suspended (chainSync connection closed)
All wallets:   Unsubscribed; DB rolled back; SeqState reset
     │
     ▼  single coordinated catch-up thread started (all wallets together)
All wallets:   CatchingUp via shared catch-up connection
     │
     ▼  tipDistance <= 1
Master thread: Resumed (new chainSync connection opened)
All wallets:   Live (re-subscribed)
```
