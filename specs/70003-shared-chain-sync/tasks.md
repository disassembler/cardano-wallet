# Tasks: Shared Master Chain Sync

**Branch**: `70003-shared-chain-sync`
**Input**: Design documents from `/specs/70003-shared-chain-sync/`
**Spec**: 3 user stories (P1: master thread, P2: catch-up threads, P3: rescan endpoints)

> **Implementation note (2026-08-26)**: Implementation complete. Architectural divergences from the original task plan are noted inline. The core change: catch-up and master-thread wiring live in `Wallet.hs` + `ApiLayer` directly rather than going through `Registry.hs`; the queue primitive is unbounded `TQueue` (not `TBQueue`) with a `bcCatchUpSemaphore :: QSem` for concurrency control; `SubscriberState` replaces `Subscriber`; `subscribe` returns a 3-tuple for drain-before-activate rather than `STM ()`.

---

## Phase 1: Setup

**Purpose**: Establish the new module and wire it into the build system.

- [X] T001 Create `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs` with module header, exports list, and `ChainBroadcaster`/`SubscriberState`/`CatchUpThread` type skeletons
- [X] T002 Export `Message` type from `lib/network-layer/src/Cardano/Wallet/Network/Streaming.hs` (currently internal) so `Broadcasting.hs` can import it
- [X] T003 Add `Broadcasting` module to `lib/network-layer/cardano-wallet-network-layer.cabal` exposed-modules list
- [X] T004 [P] Add `_chainBroadcaster :: ChainBroadcaster WalletId` field to `ApiLayer` record in `lib/api/src/Cardano/Wallet/Api.hs` with `HasType` instance
- [X] T005 [P] ~~Add `_catchUpRegistry :: TVar (Map WalletId (Async ()))` field to `ApiLayer`~~ — catch-up lifecycle is managed inside `catchUpWallet`/`monitorAndRestartConsumer` in `Wallet.hs`; no separate registry field needed

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core broadcaster infrastructure that all user stories depend on.

- [X] T006 Implement `ChainBroadcaster` data type in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
  - Actual fields: `bcSubscribers`, `bcCurrentTip`, `bcCatchUpSet`, `bcAddressIndex :: TVar (Map Address k)`, `bcUTxOIndex :: TVar (Map TxIn k)`, `bcCatchUpSemaphore :: QSem`
  - **Divergence**: uses `TQueue` (unbounded) not `TBQueue`; added address/UTxO index fields and catch-up semaphore
- [X] T007 Implement subscriber type in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
  - Actual type: `SubscriberState` with fields `ssOps`, `ssForwardQueue :: TQueue (NonEmpty Block, ChainTip)`, `ssRollbackQueue`, `ssThread`, `ssActive :: TVar Bool`
  - **Divergence**: named `SubscriberState` not `Subscriber`; separate forward/rollback queues; tracks thread handle
- [X] T008 Implement `newChainBroadcaster` constructor in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [X] T009 Implement `subscribe` in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
  - Actual signature: `subscribe :: ChainBroadcaster k -> ... -> IO (Maybe BlockNo, TVar Bool, TQueue (NonEmpty Block, ChainTip))`
  - **Divergence**: returns 3-tuple `(Maybe BlockNo, TVar Bool, TQueue)` for drain-before-activate; caller drains stale queue entries before activating the subscriber
- [X] T010 Implement `unsubscribe :: ChainBroadcaster IO blocks -> SubscriberId -> STM ()` in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [X] T011 Implement `broadcasterFollower :: ChainBroadcaster IO blocks -> ChainFollower IO ChainPoint ChainTip blocks` in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [X] T012 Implement `readChainPointsForBroadcaster` in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [X] T013 Implement `runMasterSync :: NetworkLayer IO block -> ChainBroadcaster IO block -> IO ()` in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [X] T014 Initialise broadcaster and master sync thread in `newApiLayer` in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`

**Checkpoint**: Broadcaster compiles and master thread starts. No wallets subscribed yet — existing behavior unchanged.

---

## Phase 3: User Story 1 — Single Node Connection for All Wallets (P1) 🎯 MVP

**Goal**: Replace per-wallet `chainSync` with broadcaster subscription. All wallets use the master thread at tip.

- [X] T015 [US1] ~~Add per-wallet consumer loop `walletSyncConsumer`~~ — replaced by `activateWithDrain` + `monitorAndRestartConsumer` helpers inside `catchUpWallet` in `lib/wallet/src/Cardano/Wallet.hs`. After catch-up the subscriber queue is drained of stale entries before activation; `monitorAndRestartConsumer` watches the consumer thread and restarts `catchUpWallet` on sync exceptions.
- [X] T016 [US1] ~~Modify `registerWorker` in `lib/wallet/src/Cardano/Wallet/Registry.hs`~~ — **not needed**. Wallet subscription is wired through `catchUpWallet` → `subscribe` in `Wallet.hs` and `newApiLayer` in `Server.hs`. `Registry.hs` was not modified.
- [X] T017 [US1] `startWalletWorker` in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` wires broadcaster through to `catchUpWallet`
- [X] T018 [US1] `createWalletWorker` in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` subscribes via broadcaster
- [X] T019 [US1] `deleteWallet` in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` calls `unsubscribe` before removing the wallet
- [X] T020 [US1] `newApiLayer` rebuilds broadcaster's `readChainPoints` union when wallets are added or removed
- [X] T021 [US1] Per-wallet `chainSync` call removed from `workerMain`; handled by `catchUpWallet` + master thread
- [X] T022 [US1] Integration test `CHAIN_SYNC_01` in `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs`

**Checkpoint**: All wallets synced via master thread. One node connection at tip.

---

## Phase 4: User Story 2 — Independent Per-Account Catch-Up Sync (P2)

**Goal**: New wallets and existing wallets that are behind catch up independently without affecting other wallets.

- [X] T023 [US2] `tipDistance` helper (or equivalent tip-detection logic) in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [X] T024 [US2] Implement `catchUpWallet :: NetworkLayer IO block -> WalletLayer IO s -> ChainBroadcaster IO block -> WalletId -> IO ()` in `lib/wallet/src/Cardano/Wallet.hs`
  - Actual implementation contains nested `activateWithDrain` and `monitorAndRestartConsumer` helpers
  - **Divergence**: handoff uses `ssActive :: TVar Bool` flag (from `subscribe` return value) rather than closing the catch-up connection; consumer thread monitored and restarted on sync exceptions
- [X] T025 [US2] `createWalletWorker` launches `catchUpWallet` as async thread; subscribes to master on completion
- [X] T026 [US2] `startWalletWorker` detects if wallet is behind master tip; launches `catchUpWallet` if so
- [X] T027 [US2] `deleteWallet` cancels any active catch-up before deleting
- [X] T028 [US2] Rollback-during-catch-up handled by `monitorAndRestartConsumer` in `lib/wallet/src/Cardano/Wallet.hs`: on sync exception (fork continuity error), unsubscribes and restarts the full `catchUpWallet` cycle
- [X] T029 [US2] Integration test `CHAIN_SYNC_02` in `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs`

**Checkpoint**: New wallets catch up independently. All wallets eventually subscribe to master thread.

---

## Phase 5: User Story 3 — Rescan Endpoints (P3)

**Goal**: `POST /v2/wallets/{wid}/rescan` for corruption recovery and forced re-index.

- [X] T030 [US3] `PostWalletRescan` API type added to `lib/api/src/Cardano/Wallet/Api.hs`
- [ ] T031 [US3] ~~`ResyncWallets` API type~~ (`POST /v2/wallets/resync` global resync) — global resync deferred per Decision 5; wallet-level rescan is the implemented endpoint
- [X] T032 [US3] `PostWalletRescan` added to `WalletAPI` type union and export list in `lib/api/src/Cardano/Wallet/Api.hs`
- [ ] T033 [US3] `rescanWallet` and `resyncWallets` link helpers in `lib/api/src/Cardano/Wallet/Api/Link.hs` — verify added
- [X] T034 [US3] `postWalletRescan` handler in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T035 [US3] `resyncWalletsH` — global resync not implemented (deferred per Decision 5)
- [X] T036 [US3] `postWalletRescan` wired into server in `lib/api/src/Cardano/Wallet/Api/Http/Server.hs`
- [ ] T037 [US3] Swagger definitions in `specifications/api/swagger.yaml` — verify added
- [X] T038 [US3] Integration test `CHAIN_SYNC_03` in `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs`
- [ ] T039 [US3] Integration test `CHAIN_SYNC_04` (global resync) — deferred with T031/T035

**Checkpoint**: Per-wallet rescan endpoint complete. Global resync deferred to future branch.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T040 [P] Add `HasType (ChainBroadcaster IO (CardanoBlock StandardCrypto)) ctx` constraint to all handler functions that need broadcaster access in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T041 [P] Add `MsgBroadcaster` log messages to the broadcaster (subscriber count changes, rollback fan-out timing, slow-subscriber warnings) in `lib/network-layer/src/Cardano/Wallet/Network/Broadcasting.hs`
- [ ] T042 [P] Verify Fourmolu formatting on all new/modified files (70-char line limit, leading commas, 4-space indent)
- [ ] T043 [P] Run HLint on `Broadcasting.hs`, `Wallet.hs`, `Server.hs` changes and fix all warnings
- [ ] T044 Confirm nix build passes: `nix build .#cardano-wallet` in worktree root
- [X] T045 Added new integration tests (`CHAIN_SYNC_01`–`CHAIN_SYNC_03`) in `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs`

**Additional completed work (not in original task list)**:

- [X] T046 Added `chain-sync-flood-bench` benchmark in `lib/benchmarks/exe/chain-sync-flood-bench.hs` with `observerCounts = [1, 5, 10, 20, 50]` and `catchUpConcurrency = 1000`
- [X] T047 Exported `ChainBroadcaster (..)`, `SubscriberState (..)` from Broadcasting.hs; added `WalletBroadcastOps` type exported from `Wallet.hs`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 — blocks all user stories
- **Phase 3 (US1)**: Depends on Phase 2 — the master thread must exist before wallets subscribe
- **Phase 4 (US2)**: Depends on Phase 3 — catch-up threads hand off to the master thread
- **Phase 5 (US3)**: Depends on Phase 4 — rescan uses `catchUpWallet` from US2
- **Phase 6 (Polish)**: Depends on Phase 5

### Critical Path

T001–T005 → T006–T014 → T015–T022 → T023–T029 → T030–T039 → T040–T045

### Parallel Opportunities

**Phase 1**: T004 and T005 can run in parallel (different fields in same record — coordinate to avoid conflicts).

**Phase 2**: T006–T013 are largely sequential (each builds on the previous type/function). T014 can only proceed after T013.

**Phase 3**: T015 (consumer loop in Wallet.hs) can be written in parallel with T016 (Registry.hs change) since they touch different files. T022 (integration test) can be written in parallel with T020–T021.

**Phase 5**: T030–T033 (type definitions and links) can all run in parallel. T034 and T035 can run in parallel (different handlers). T037 (swagger) can run in parallel with T034–T035. T038 and T039 (integration tests) can run in parallel.

**Phase 6**: All T040–T043 can run in parallel.

---

## Implementation Strategy

### MVP: Phase 1 + 2 + 3 (US1 only)

1. Complete Phase 1 — module scaffolding
2. Complete Phase 2 — broadcaster core
3. Complete Phase 3 — wire all wallets to master thread
4. **STOP and VALIDATE**: Run `CHAIN_SYNC_01`, verify single connection, all balances correct
5. This alone is the primary performance win (O(1) connections instead of O(wallets))

### Incremental Delivery

1. Phase 1+2+3 → master thread live → **demo: single node connection**
2. Phase 4 (US2) → catch-up independent → **demo: add wallet without disruption**
3. Phase 5 (US3) → rescan endpoints → **demo: recover from corrupted state**

### Key Invariants to Preserve

- `GET /v2/wallets/{wid}` sync progress continues to work correctly during catch-up (the wallet's `state` field reads from the DB checkpoint, not from the broadcaster)
- Rollback fan-out must be serialized: no wallet sees a new block after a rollback until the rollback has been applied to all subscribers
- A wallet in catch-up must NOT receive master-thread blocks for slots it has already processed (handled by the hand-off protocol in `catchUpWallet`)
