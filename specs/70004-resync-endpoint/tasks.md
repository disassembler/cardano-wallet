# Tasks: Wallet Chain Continuity Recovery and Rescan Endpoint

**Input**: Design documents from `/specs/70004-resync-endpoint/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/rescan-endpoint.md ✓

**Organization**: Tasks are grouped by user story to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no unresolved dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)

---

## Phase 1: Setup

**Purpose**: Locate the prototype work in `70002-shelley-multi-account` that will be ported to this branch.

- [ ] T001 Identify rescan-related commits in `70002-shelley-multi-account` to cherry-pick — run `git log 70002-shelley-multi-account --oneline` and list commits touching `postWalletRescanH`, the rescan DB reset, and the route definition

---

## Phase 2: Foundational (Blocking Prerequisite)

**Purpose**: Replace the stringly-typed `fail` call with a proper typed exception. Both US1 (catch-and-recover) and the diagnostic logging depend on having a structured error value to inspect.

**⚠️ CRITICAL**: US1 implementation cannot begin until T002 is complete.

- [ ] T002 In `lib/wallet/src/Cardano/Wallet.hs` (~line 1499), replace the `fail` string in `restoreBlocks` with `throwIO ErrChainNotContinuation{storedTip = currentTip cp0, incomingBlock = firstHeader blocks}` — add `data ErrChainNotContinuation = ErrChainNotContinuation { storedTip :: BlockHeader, incomingBlock :: BlockHeader }` and its `Exception` instance near the other error types (~line 5046)

**Checkpoint**: `ErrChainNotContinuation` is throwable; `restoreBlocks` no longer calls `fail`; code compiles with `-Wall`.

---

## Phase 3: User Story 1 — Automatic Recovery from Chain Continuity Error (Priority: P1) 🎯 MVP

**Goal**: Wallet workers catch chain continuity errors, roll back to the deepest available checkpoint, and retry chain sync exactly once — without crashing or requiring operator intervention.

**Independent Test**: Inject a simulated chain continuity mismatch in a unit test; verify the worker does not throw, rolls back, retries, and emits a structured `Warning` log entry. No API call required.

### Implementation for User Story 1

- [ ] T004 [US1] In `lib/wallet/src/Cardano/Wallet.hs`, add `ErrChainContinuityUnrecoverable` data type and `Exception` instance near the other error types (~line 5046); add `MsgChainContinuityRecovery` (with fields: wallet ID, stored tip, incoming block, rollback target slot) and `MsgChainContinuityUnrecoverable` constructors to `WalletWorkerLog` (~line 5155); set severities to `Warning` and `Error` respectively; update the `ToText` instance to render human-readable messages
- [ ] T003 [US1] In `lib/wallet/src/Cardano/Wallet.hs`, modify `restoreWallet` (~line 1396) to implement a two-step recovery when `ErrChainNotContinuation` is caught: **Step 1** — roll back to `last` of `atomically listCheckpoints` (listCheckpoints returns oldest-to-newest; if the list is empty, skip to Step 2) and retry `chainSync`; if Step 1 retry also throws `ErrChainNotContinuation`, proceed to **Step 2** — call `rollbackBlocks ctx (toSlot Origin)` (roll back to genesis) and retry `chainSync` once more; if Step 2 also throws `ErrChainNotContinuation`, throw `ErrChainContinuityUnrecoverable` (wrong network / configuration error) and halt cleanly; emit `MsgChainContinuityRecovery` on each successful step, `MsgChainContinuityUnrecoverable` on final failure (types defined in T004 — T004 must compile first)
- [ ] T005 [US1] In the appropriate unit test file (search for `WalletSpec` or `restoreBlocks` tests under `lib/unit/test/`), add tests: (a) `ErrChainNotContinuation` → rollback-and-retry → success path; (b) `ErrChainNotContinuation` → rollback-and-retry → second failure → clean halt (no infinite loop); (c) `MsgChainContinuityRecovery` is emitted at `Warning` severity on recovery
- [ ] T006 [US1] In `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs`, add integration test `CHAIN_RECOVERY_01`: restore a wallet, stop the node, manually corrupt the wallet's checkpoint in the DB (or use a mock chain layer that presents a non-continuation block), restart, then poll `GET /v2/wallets/{wid}` for up to 60 seconds asserting `state.status` transitions away from any dead/stuck state to `"syncing"` (SC-002 timing SLA); also assert log output contains `MsgChainContinuityRecovery` at `Warning` severity

**Checkpoint**: Wallet self-heals after a chain continuity error. Unit tests pass. `GET /v2/wallets/{wid}` reflects live progress after recovery. Worker does not restart infinitely on unrecoverable error.

---

## Phase 4: User Story 2 — Force Rescan via API (Priority: P2)

**Goal**: `POST /v2/wallets/{walletId}/rescan` resets a wallet to genesis and restarts its worker. Returns 202 immediately; 404 for unknown wallet; 409 if already rescanning.

**Independent Test**: Call `POST /v2/wallets/{wid}/rescan` on a synced wallet, verify 202 response, then poll `GET /v2/wallets/{wid}` and observe `state.status = "syncing"` with progress near 0%.

### Implementation for User Story 2

- [ ] T007 [US2] Cherry-pick rescan-related commits identified in T001 from `70002-shelley-multi-account` onto `70004-resync-endpoint` as a starting point — resolve any merge conflicts introduced by the Phase 2/3 changes; compile and verify the cherry-picked code does not regress existing tests
- [ ] T008 [P] [US2] In `lib/api/src/Cardano/Wallet/Api.hs`, add `RescanWallet` Servant route: `"wallets" :> Capture "walletId" WalletId :> "rescan" :> ReqBody '[JSON] () :> PostAccepted '[JSON] ()`
- [ ] T009 [P] [US2] In `lib/api/src/Cardano/Wallet/Api/Types.hs`, add `newtype ErrRescanAlreadyRunning = ErrRescanAlreadyRunning WalletId` with `Exception` instance
- [ ] T010 [P] [US2] In `lib/api/src/Cardano/Wallet/Api/Http/Server/Error.hs`, add `IsServerError ErrRescanAlreadyRunning` instance that maps to HTTP 409 with error code `"rescan_already_running"` and message matching the contract in `specs/70004-resync-endpoint/contracts/rescan-endpoint.md`
- [ ] T011 [P] [US2] In `lib/api/src/Cardano/Wallet/Api/Link.hs`, add `postWalletRescan :: forall style. Wallet style -> Link` link helper following the existing pattern for other wallet endpoints
- [ ] T012 [US2] Search for `WorkerCtx` or `workerRegistry` in `lib/application/shelley/Cardano/Wallet/Application.hs` and `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` to locate the per-wallet worker context record; add `rescanInProgress :: TVar Bool` to that record, initialized to `newTVarIO False` when the worker is started; expose a read accessor so the API handler (T014) can check and set it atomically
- [ ] T013 [US2] In `lib/wallet/src/Cardano/Wallet.hs`, implement `forceRescanWallet :: WalletLayer IO s -> IO ()` that: (a) calls `atomically $ rollbackTo Origin` to clear UTxO/tx/delegation history, (b) resets address discovery state to the initial gap-limit state (search for how address discovery state is initialized at wallet creation to replicate that reset), (c) is safe to call atomically before restarting the worker
- [ ] T014 [US2] In `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`, implement `postWalletRescanH` handler: check wallet exists (404 if not), check `RescanStatus` TVar (409 if `True`), set TVar to `True`, return 202, then asynchronously call `forceRescanWallet` and restart the worker via the registry; clear TVar to `False` once the worker successfully begins applying blocks
- [ ] T015 [P] [US2] In `specifications/api/swagger.yaml`, add the `POST /v2/wallets/{walletId}/rescan` endpoint definition per `specs/70004-resync-endpoint/contracts/rescan-endpoint.md` — include 202, 404, and 409 response schemas
- [ ] T016 [US2] In `lib/integration/scenarios/Test/Integration/Scenario/API/Shelley/ChainSync.hs`, add integration tests:
  - `RESCAN_01`: 202 on synced wallet; record start time and assert response arrives within 1000ms (SC-003); poll `GET /v2/wallets/{wid}` and assert progress resets to near 0%
  - `RESCAN_02`: 409 if called while rescanning (trigger rescan, immediately call again before it completes)
  - `RESCAN_03`: 404 for unknown wallet ID
  - `RESCAN_04`: wallet reaches same balance, UTxO set, and tx history as a fresh restore from the same mnemonic after rescan completes (SC-004)
  - `RESCAN_05`: while rescan is in progress, attempt to construct or submit a transaction via the wallet endpoints; assert a clear not-ready error is returned (FR-013) and the wallet still appears in `GET /v2/wallets`

**Checkpoint**: `POST /v2/wallets/{wid}/rescan` returns correct status codes. Wallet rebuilds to correct final state after a full rescan. All four integration test scenarios pass.

---

## Phase 5: User Story 3 — SQLite Churn Verification (Priority: P3)

**Goal**: Confirm that the "Closing single database connection" log churn is eliminated as a side-effect of US1/US2. No new code required; this is a verification task.

**Independent Test**: After US1 recovery or US2 rescan, assert that the log entry count for "Closing single database connection" per `GET /v2/wallets` request matches the healthy baseline (not the elevated rate seen when workers are dead).

- [ ] T017 [US3] In the `CHAIN_RECOVERY_01` integration test (T006), add an assertion that counts "Closing single database connection" log entries per `GET /v2/wallets/{wid}` request after recovery; assert the count is ≤ 1 per request (SC-005 baseline: at most 1 connection close per healthy read, vs 7+ when workers are dead); add a code comment citing this expected value so future regressions are immediately visible

**Checkpoint**: SQLite connection churn is demonstrably bounded to the healthy baseline after recovery.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T021 [P] In the api library's test suite (search for existing handler tests under `lib/unit/test/` or `lib/api/test/`), add unit tests for `postWalletRescanH` covering: (a) 404 branch — `withWorkerCtx` returns not-found; (b) 409 branch — `rescanInProgress TVar` is `True`; (c) 202 branch — TVar is `False`, handler sets it to `True`, returns 202, and dispatches the async reset
- [ ] T018 [P] Run `fourmolu --mode check` on all modified `.hs` files and fix any formatting violations (70-char line limit, leading commas, 4-space indent per constitution)
- [ ] T019 [P] Run `hlint` on all modified `.hs` files and resolve any warnings
- [ ] T020 Add entries to `bump-changelog.md` for: (a) bug fix — automatic chain continuity recovery in wallet engine; (b) new endpoint — `POST /v2/wallets/{walletId}/rescan`

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 (T001 informs T002 scoping) — BLOCKS US1 (T003/T004)
- **US1 (Phase 3)**: Depends on Phase 2 (T002) — T003 and T004 can run in parallel with each other
- **US2 (Phase 4)**: Independent of US1 — can start after Phase 1; T008–T011 can all run in parallel
- **US3 (Phase 5)**: Depends on T006 existing (adds assertion to it) — effectively concurrent with Phase 3 completion
- **Polish (Phase 6)**: Depends on all phases complete

### User Story Dependencies

- **US1 (P1)**: Depends on T002 (typed exception). T004 (error types + log constructors) must complete before T003 (two-step rollback logic in restoreWallet), because T003 references `ErrChainContinuityUnrecoverable` and the new log constructors defined in T004. Order: T002 → T004 → T003 → T005 → T006.
- **US2 (P2)**: Largely independent of US1. T007 (cherry-pick) is the entry point; T008–T011 run in parallel; T012 before T014; T013 before T014; T015 is parallel.
- **US3 (P3)**: Amendment to T006 — complete after T006.

### Parallel Opportunities

**US1 sequential tasks** (after T002):
- T004 (error types + log constructors) must complete first; T003 (restoreWallet catch-retry) depends on the types T004 defines

**US2 parallel tasks** (after T007 cherry-pick resolves):
- T008 (route), T009 (error type), T010 (error instance), T011 (link helper), T015 (swagger) — all different files, fully parallel

---

## Parallel Example: User Story 2

```text
# After T007 (cherry-pick) resolves, launch these in parallel:
T008: Add RescanWallet route to lib/api/src/Cardano/Wallet/Api.hs
T009: Add ErrRescanAlreadyRunning to lib/api/src/Cardano/Wallet/Api/Types.hs
T010: Add IsServerError instance to lib/api/src/Cardano/Wallet/Api/Http/Server/Error.hs
T011: Add postWalletRescan link to lib/api/src/Cardano/Wallet/Api/Link.hs
T015: Update specifications/api/swagger.yaml

# Then sequentially:
T012: Add RescanStatus TVar to worker context (must precede T014)
T013: Implement forceRescanWallet in lib/wallet/src/Cardano/Wallet.hs (must precede T014)
T014: Implement postWalletRescanH handler (depends on T008–T013)
T016: Integration tests (depends on T014)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: T001
2. Complete Phase 2: T002
3. Complete Phase 3: T004 → T003 → T005 → T006
4. **STOP and VALIDATE**: Unit tests pass; wallet self-heals in integration test without any API call
5. This alone fixes the production bug — the rescan endpoint is additive

### Incremental Delivery

1. Setup + Foundational (T001–T002) → typed exception in place
2. US1 (T003–T006) → wallet self-heals; deploy as hotfix if needed
3. US2 (T007–T016) → rescan endpoint available; deploy as feature
4. US3 (T017) → churn verified; included in US1 integration test
5. Polish (T018–T020) → ready for PR

---

## Notes

- **Cherry-pick strategy (T007)**: The 70002 prototype may have been built on a different base. Prefer cherry-picking the minimal set of commits (handler + DB reset + route wiring) rather than rebasing the entire branch. Check for conflicts with the T002 `ErrChainNotContinuation` change.
- **Address discovery reset (T013)**: The exact call needed to reset address discovery state depends on the wallet type (`s` parameter). Search for how the initial discovery state is set during `createWallet` to find the right reset operation. For sequential wallets this is likely resetting the gap counter and address pool; for random wallets it may be a no-op beyond the UTxO reset.
- **Worker restart after rescan (T014)**: The worker registry restart mechanism already exists for handling worker crashes. Reuse it rather than implementing a new lifecycle path.
- **`rollbackTo Origin` semantics (T013)**: Verify that `rollbackTo` with the genesis `ChainPoint` (or `Origin`) clears all derived tables. If the genesis checkpoint is not in the checkpoint table after a rollback (it may be implicitly represented), the worker restart from genesis must re-insert it.
