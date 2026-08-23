# Tasks: Shelley Wallet Multi-Account Support

**Input**: Design documents from `/specs/70002-shelley-multi-account/`  
**Prerequisites**: plan.md ✓ spec.md ✓ research.md ✓ data-model.md ✓ contracts/ ✓

**Organization**: Tasks grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no blocking dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5, maps to spec.md)

## Path Conventions

Monorepo under `lib/`. All paths are relative to the worktree root.

---

## Phase 1: Setup

**Purpose**: Verify the starting baseline before any changes are made.

- [ ] T001 Verify baseline build and tests pass: `cabal build all && cabal test all` in worktree root

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core type layer + DB schema + migration + wallet-layer stubs. ALL user story phases depend on this phase being complete.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### Type Layer (`lib/address-derivation-discovery/`)

- [ ] T002 Add `SeqStates n k` wrapper type (`newtype SeqStates n k = SeqStates { getSeqStates :: Map (Index 'Hardened 'AccountK) (SeqState n k) }`) in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs`
- [ ] T003 Implement `IsOurs (SeqStates n k)` instance — dispatches to whichever member `SeqState` recognises the address — in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs`
- [ ] T004 Implement `IsOwned (SeqStates n k)` instance, removing the "only one account" assumption (line ~606) — iterates all member `SeqState`s to find the owning account then derives its private key — in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs`
- [ ] T005 Implement `GenChange (SeqStates n k)` instance in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs`; `ArgGenChange (SeqStates n k)` must include an `Index 'Hardened 'AccountK` to identify which member `SeqState` to generate change for (callers extract the right `SeqState` from the map by account index and delegate); alternatively, `GenChange` is invoked on the extracted `SeqState` directly — document the chosen dispatch pattern explicitly
- [ ] T006 [P] Add `mkSeqStateForAccount :: Index 'Hardened 'AccountK -> ClearCredentials k -> AddressPoolGap -> ChangeAddressMode -> SeqState n k` in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Keys/SequentialAny.hs` (parallel with T007 — different file)

### DB Schema (`lib/wallet/`)

- [ ] T007 [P] Add `accountIndex Word32` column to `SeqState`, `SeqStateAddress`, `SeqStatePendingIx`, and `TxMeta` Persistent entity definitions in `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Schema.hs`; update primary key tuples to include `accountIndex` (parallel with T006 — different file)
- [ ] T008 Create `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Migration/V6.hs`: `ALTER TABLE … ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0` for the four tables, then rebuild each with the new composite PK via rename-create-copy-drop
- [ ] T009 Register `V6.migrateAccounts` as the `5 → 6` step in the migration chain in `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Migration/New.hs`
- [ ] T010 Update `insertPrologue` and `loadPrologue` in `lib/wallet/src/Cardano/Wallet/DB/Store/Checkpoints/Store.hs` to read and write `accountIndex` on all four tables; all queries now filter by `(walletId, accountIndex)` rather than `walletId` alone

### Wallet Layer (`lib/wallet/`)

- [ ] T011 Add `addWalletAccount :: WalletId -> Index 'Hardened 'AccountK -> ExceptT ErrAddAccount IO ()`, `listWalletAccounts :: WalletId -> IO [AccountSummary]`, and `deleteWalletAccount :: WalletId -> Index 'Hardened 'AccountK -> ExceptT ErrDeleteAccount IO ()` to `lib/wallet/src/Cardano/Wallet/Wallet.hs`; define `ErrAddAccount = ErrAddAccountDuplicate | ErrAddAccountNoSuchWallet` (attempting to add 0H returns `ErrAddAccountDuplicate` because 0H already exists — no special error needed) and `ErrDeleteAccount = ErrDeleteAccountIsDefault | ErrDeleteAccountNoSuchWallet` (0H deletion returns `ErrDeleteAccountIsDefault`)
- [ ] T012 Add `readAccountUTxO :: WalletId -> Index 'Hardened 'AccountK -> IO UTxO` to `lib/wallet/src/Cardano/Wallet/Wallet.hs` — calls `readWalletUTxO` then filters to outputs whose addresses are owned by the `SeqState` for that account index

### API Infrastructure (`lib/api/`)

- [ ] T013 [P] Add `ApiAccount { accountIndex :: ApiT DerivationIndex, balance :: ApiWalletBalance, assets :: ApiWalletAssetsBalance, delegation :: ApiWalletDelegation, rewardAccountKey :: Maybe Text, addressPoolGap :: ApiT AddressPoolGap, addressDerivationMode :: AccountMode, state :: ApiT SyncProgress, tip :: ApiBlockReference }`, `ApiPostAccount { accountIndex :: ApiT DerivationIndex }`, and `AccountMode` sum type (`AccountModeHD | AccountModeSingleAddress`, serialised as `"hd"` / `"single_address"`) to `lib/api/src/Cardano/Wallet/Api/Types.hs` (parallel with T014; includes the mode field from former T042 — T042 is removed)
- [ ] T014 [P] Add `WalletAccounts` Servant type alias with all 10 routes (`POST /accounts`, `GET /accounts`, `GET /accounts/:idx`, `DELETE /accounts/:idx`, `GET /accounts/:idx/addresses`, `GET /accounts/:idx/utxo/statistics`, `POST /accounts/:idx/transactions`, `GET /accounts/:idx/transactions`, `PUT /accounts/:idx/mode`, `POST /accounts/:idx/utxo/consolidate`) using `Capture "accountIndex" (ApiT DerivationIndex)` in `lib/api/src/Cardano/Wallet/Api.hs` (parallel with T013; all routes defined upfront so the Servant type is complete from the start)
- [ ] T015 Wire `WalletAccounts` into the `Api n` type in `lib/api/src/Cardano/Wallet/Api.hs` and add stub handler bindings (returning `throwError err501` — HTTP 501, not `error` which would panic the process) in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` so the project compiles end-to-end

**Checkpoint**: Full project compiles with stubs. All existing tests pass. Foundation ready — user story phases can now begin.

---

## Phase 3: User Story 1 — Add Account (Priority: P1) 🎯 MVP

**Goal**: A user can call `POST /wallets/{walletId}/accounts` with a chosen hardened index and get back a freshly initialised `ApiAccount`. Non-sequential gaps are allowed (3H without 1H/2H is valid).

**Independent Test**: `POST /wallets/{id}/accounts` with body `{"account_index":"3H"}` on a wallet that only has 0H returns HTTP 201 with `account_index: "3H"` and zero balance; a second identical call returns HTTP 409.

- [ ] T016 [US1] Implement `postWalletAccount` handler: call `addWalletAccount`, return `ApiAccount` (201); on `ErrAddAccountDuplicate` return 409; on `ErrAddAccountNoSuchWallet` return 404 in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T017 [US1] Map `ErrAddAccount` variants to HTTP responses (`ErrAddAccountDuplicate` → 409, `ErrAddAccountNoSuchWallet` → 404) via the `AsServantError` / `IsServerError` machinery in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T018 [US1] Unit test: `addWalletAccount` on a fresh wallet with index 3H succeeds; adding 0H (which always exists) returns `ErrAddAccountDuplicate` (409); adding 3H twice also returns `ErrAddAccountDuplicate` in `lib/wallet/test/unit/Cardano/Wallet/Wallet/AccountSpec.hs`

**Checkpoint**: `POST /wallets/{id}/accounts` is fully functional. US1 independently testable.

---

## Phase 4: User Story 2 — Inspect Per-Account Balance and UTXOs (Priority: P2)

**Goal**: A user can query the balance and UTXO statistics for a specific account in isolation. Funding account 1H does not alter account 0H's balance.

**Independent Test**: Fund account 1H on a local cluster; `GET /wallets/{id}/accounts/1H` returns only 1H's balance; `GET /wallets/{id}/accounts/0H` returns zero balance (unchanged).

- [ ] T019 [P] [US2] Implement `getWalletAccount` handler for `GET /wallets/{id}/accounts/{idx}`: look up the `SeqState` for the given account index, compute balance from `readAccountUTxO`, return `ApiAccount`; return 404 if the index has not been added in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T020 [P] [US2] Implement `getWalletAccountUtxoStatistics` handler for `GET /wallets/{id}/accounts/{idx}/utxo/statistics`: call `readAccountUTxO`, compute distribution statistics (same logic as existing `GET /wallets/{id}/utxo/statistics` but scoped to one account) in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T021 [US2] Update `getWallet` handler aggregate balance computation to sum balances across all registered accounts for the wallet in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`

**Checkpoint**: Balance isolation verified. US2 independently testable.

---

## Phase 5: User Story 3 — Send Transaction from Specific Account (Priority: P3)

**Goal**: A user can submit a transaction from account NH using only that account's UTxOs. Insufficient funds in account NH returns 422 — the wallet never falls back to another account. Change goes to NH's internal pool.

**Independent Test**: Fund 0H (10 ADA) and 1H (5 ADA) on a local cluster; attempt to send 8 ADA from 1H → 422 (insufficient); send 3 ADA from 1H → succeeds; inspect inputs: all are 1H addresses; inspect change output: 1H internal address.

- [ ] T022 [US3] Implement the per-account UTxO filter in `readAccountUTxO` in `lib/wallet/src/Cardano/Wallet/Wallet.hs`: after `readWalletUTxO`, retain only outputs whose address is recognised by the `SeqState` for the requested account index (via `isOurs`)
- [ ] T023 [US3] Implement `postWalletAccountTransaction` handler: build coin selection using only `readAccountUTxO` output (no fallback), sign using the account's key, submit; return 422 with `ErrInsufficientFundsForAccount` when balance is too low in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T024 [US3] Implement `listWalletAccountTransactions` handler for `GET /wallets/{id}/accounts/{idx}/transactions`: query `TxMeta` scoped to `(walletId, accountIndex)` in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T025 [US3] Unit test: construct a transaction from account 1H; assert every `TxIn` address is a `SeqState`-recognised address for account 1H; assert change output address is from account 1H's internal pool; assert `readAccountUTxO` for account 0H excludes all 1H UTxOs in `lib/wallet/test/unit/Cardano/Wallet/Wallet/AccountSpec.hs`

**Checkpoint**: Strict coin isolation verified end-to-end. US3 independently testable.

---

## Phase 6: User Story 4 — List Addresses per Account (Priority: P4)

**Goal**: `GET /wallets/{id}/accounts/{idx}/addresses` returns only addresses derived from account index NH. No address from another account appears in the list.

**Independent Test**: Call the endpoint for account 2H; decode each returned address; confirm every derivation path starts with `1852H/1815H/2H/`.

- [ ] T026 [US4] Implement `listWalletAccountAddresses` handler for `GET /wallets/{id}/accounts/{idx}/addresses`: query `SeqStateAddress` rows filtered by `(walletId, accountIndex)`, respect optional `?state=used|unused` query param, return `[ApiAddressWithPath n]` in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T027 [US4] Unit test: for a wallet with accounts 1H and 2H, addresses returned for 1H all have derivation path prefix `1852H/1815H/1H`; no address appears in both lists in `lib/wallet/test/unit/Cardano/Wallet/Wallet/AccountSpec.hs`

**Checkpoint**: Address isolation verified. US4 independently testable.

---

## Phase 7: User Story 5 — List All Accounts (Priority: P5)

**Goal**: `GET /wallets/{id}/accounts` returns all registered accounts in ascending index order, each with its own balance.

**Independent Test**: Create a wallet, add accounts 1H and 5H; call `GET /wallets/{id}/accounts`; verify 3 entries (0H, 1H, 5H) in ascending order; verify sum of balances equals `GET /wallets/{id}` total balance.

- [ ] T028 [US5] Implement `listWalletAccounts` handler for `GET /wallets/{id}/accounts`: call `listWalletAccounts` wallet-layer function, map each `AccountSummary` to `ApiAccount`, return list sorted ascending by account index in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T029 [US5] Unit test: wallet with accounts 0H, 1H, 5H returns exactly 3 entries in ascending index order; balances are individually correct and sum to total wallet balance in `lib/wallet/test/unit/Cardano/Wallet/Wallet/AccountSpec.hs`

**Checkpoint**: All five user stories independently functional.

---

## Phase 8: User Story 6 — Toggle Single-Address Mode (Priority: P6)

**Goal**: A user can PUT `{"mode": "single_address"}` to any account and from that point forward, all change outputs go to `/0/0` — no `/1/N` internal-chain keys are ever derived or used. Toggling back to `hd` restores normal behaviour.

**Independent Test**: Toggle account 1H to `single_address`, construct a transaction, inspect the change output address — it must equal the account's `/0/0` address. Verify no `SeqStateAddress` rows with `role = UtxoInternal` are created during or after the transaction.

- [ ] T037 [US6] Add `SingleExternalAddress` variant to the `ChangeAddressMode` data type in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery.hs`; update `Buildable`, `NFData`, `ToJSON`/`FromJSON` instances
- [ ] T038 [US6] Add `SingleExternalAddress` case in `genChange` for `SeqState` in `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs`: use `UtxoExternal` role at `minBound` index (derives `/0/0`) instead of the internal pool; no `pendingChangeIxs` update needed in this mode
- [ ] T039 [US6] Add `setAccountMode :: WalletId -> Index 'Hardened 'AccountK -> ChangeAddressMode -> ExceptT ErrNoSuchWallet IO ()` to `lib/wallet/src/Cardano/Wallet/Wallet.hs`; persists updated `changeAddrMode` in the `SeqState` table row for `(walletId, accountIndex)` — no schema migration needed as the column already exists
- [ ] T040 [US6] Add `ApiSetAccountMode { mode :: AccountMode }` type to `lib/api/src/Cardano/Wallet/Api/Types.hs` (route was already added in T014; this task adds only the request body type)
- [ ] T041 [US6] Implement `putWalletAccountMode` handler in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`: call `setAccountMode`, return updated `ApiAccount` with `addressDerivationMode` field populated from the new `AccountMode` type defined in T013 (maps `SingleExternalAddress` → `AccountModeSingleAddress`, others → `AccountModeHD`)
- [ ] T043 [US6] Unit test: after `setAccountMode 1H SingleExternalAddress`, `genChange` on account 1H returns an address with derivation path `/0/0`; after toggling back to `IncreasingChangeAddresses`, it returns `/1/N` addresses again in `lib/wallet/test/unit/Cardano/Wallet/Wallet/AccountSpec.hs`

**Checkpoint**: Single-address mode is toggleable and verifiably routes change to `/0/0`. US6 independently testable.

---

## Phase 9: User Story 7 — Consolidate UTXOs to /0/0 (Priority: P7)

**Goal**: A user can POST to the consolidate endpoint with their passphrase and all account UTXOs are swept into a single output at `/0/0`. Partial consolidation (too many UTXOs for one tx) returns `"complete": false`. An already-consolidated account returns `"complete": true` with no transaction.

**Independent Test**: Fund account 2H with UTXOs at 5 different derived addresses; call consolidate; verify the submitted transaction has 5 inputs (all 2H addresses) and 1 output (the `/0/0` address); call consolidate again; verify `"complete": true` and no transaction.

- [ ] T044 [US7] Add `consolidateAccountUtxo :: WalletId -> Index 'Hardened 'AccountK -> Passphrase "user" -> ExceptT ErrConsolidate IO ConsolidateResult` to `lib/wallet/src/Cardano/Wallet/Wallet.hs`; define `ConsolidateResult = AlreadyConsolidated | Consolidated ApiTransaction | PartiallyConsolidated ApiTransaction` and `ErrConsolidate = ErrConsolidateWrongPassphrase | ErrConsolidateNoSuchWallet | ErrConsolidateEmptyAccount` so wrong-passphrase (→ 403), missing wallet/account (→ 404), and empty account (→ 422) can all surface cleanly in the handler
- [ ] T045 [US7] Implement the select-all coin selection strategy in `consolidateAccountUtxo`: call `readAccountUTxO` to get the full UTXO set, check if it is already a single UTXO at `/0/0` (→ `AlreadyConsolidated`), otherwise select as many inputs as fit within max transaction size limits and build a transaction with a single output at `deriveAddressPublicKey accountXPub UtxoExternal minBound` for `(totalInput - fee)` in `lib/wallet/src/Cardano/Wallet/Wallet.hs`
- [ ] T046 [US7] Add `ApiConsolidateResponse` type (`{ complete :: Bool, transaction :: Maybe ApiTransaction }`) to `lib/api/src/Cardano/Wallet/Api/Types.hs`
- [ ] T047 [US7] Add `ApiConsolidateRequest { passphrase :: ApiT (Passphrase "user") }` request body type to `lib/api/src/Cardano/Wallet/Api/Types.hs` (route was already declared in T014)
- [ ] T048 [US7] Implement `postWalletAccountConsolidate` handler in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`: call `consolidateAccountUtxo`, map `ConsolidateResult` to `ApiConsolidateResponse`; `AlreadyConsolidated` → 202 with `complete: true`; `Consolidated tx` → 202 with `complete: true, transaction: tx`; `PartiallyConsolidated tx` → 202 with `complete: false, transaction: tx`
- [ ] T049 [US7] Unit test: `consolidateAccountUtxo` with 3 UTXOs at different addresses produces a transaction with 3 inputs all belonging to the account; calling again after the transaction is confirmed returns `AlreadyConsolidated`; calling on an empty account returns 422 in `lib/wallet/test/unit/Cardano/Wallet/Wallet/AccountSpec.hs`

**Checkpoint**: Consolidation endpoint sweeps UTXOs to `/0/0` correctly in one or multiple calls. US7 independently testable.

---

## Phase 10: Polish & Cross-Cutting Concerns

**Purpose**: Delete endpoint, swagger, Haddock, integration tests (US6+US7), performance check, regression run, formatting, and compile gate.

- [ ] T030 [P] Implement `deleteWalletAccount` handler for `DELETE /wallets/{id}/accounts/{idx}`: call `deleteWalletAccount` wallet-layer function; return 204 on success; 403 (`ErrDeleteAccountIsDefault`) for account 0H; 404 if index not found in `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs`
- [ ] T031 [P] Merge `specs/70002-shelley-multi-account/contracts/api-accounts.yaml` schemas and paths into `specifications/api/swagger.yaml` — add all schemas (`ApiPostAccount`, `ApiAccount`, `ApiAccountSummaryList`, `ApiSetAccountMode`, `ApiConsolidateResponse`) and all 10 paths under `/wallets/{walletId}/accounts`
- [ ] T032 [P] Add Haddock documentation to ALL new public symbols: `SeqStates`, `IsOurs`/`IsOwned`/`GenChange` instances, `mkSeqStateForAccount`, `SingleExternalAddress` (and its `Buildable`/`ToJSON`/`FromJSON` instances) in `lib/address-derivation-discovery/`; `addWalletAccount`, `listWalletAccounts`, `deleteWalletAccount`, `readAccountUTxO`, `setAccountMode`, `consolidateAccountUtxo`, `ErrAddAccount`, `ErrDeleteAccount`, `ErrConsolidate`, `ConsolidateResult` in `lib/wallet/src/Cardano/Wallet/Wallet.hs`; `ApiAccount`, `AccountMode`, `ApiSetAccountMode`, `ApiConsolidateResponse`, `ApiConsolidateRequest` in `lib/api/src/Cardano/Wallet/Api/Types.hs`
- [ ] T033 Integration test (original lifecycle): restore wallet (0H present), add 3H, fund 3H via test cluster faucet, send 1 ADA from 3H, verify 0H balance is unchanged, delete 3H, verify 404 on subsequent GET in `lib/wallet-e2e/test/e2e/Cardano/Wallet/E2ESpec.hs`
- [ ] T050 [P] Integration test (US6 — single-address mode on cluster): add account 1H, toggle it to `single_address` mode, fund 1H, send a transaction, assert change output address equals 1H's `/0/0` address and no `SeqStateAddress` row with `role = UtxoInternal` was created for this transaction in `lib/wallet-e2e/test/e2e/Cardano/Wallet/E2ESpec.hs`
- [ ] T051 [P] Integration test (US7 — consolidation on cluster): add account 2H, fund it with UTxOs at 3 different derived addresses via the faucet, call `POST /consolidate`, assert the resulting transaction has 3 inputs (all 2H addresses) and 1 output at 2H's `/0/0`; call consolidate again and assert `"complete": true` with no transaction in `lib/wallet-e2e/test/e2e/Cardano/Wallet/E2ESpec.hs`
- [ ] T052 Performance check: seed a test SQLite DB with 20 accounts each having 500 UTxO rows, time `GET /wallets/{id}/accounts`, assert response time < 2 s; document result in a comment in `lib/wallet-e2e/test/e2e/Cardano/Wallet/E2ESpec.hs` or a standalone benchmark module
- [ ] T053 End-of-feature regression run: execute `cabal test all` after all implementation tasks complete and confirm the full pre-existing test suite passes with zero failures (complements T001 which established the baseline)
- [ ] T034 [P] Run Fourmolu formatter (`fourmolu --mode inplace`) on all modified `.hs` files and commit formatting fixes
- [ ] T035 [P] Run HLint on all modified `.hs` files; resolve all warnings that are not suppressed by the project's `.hlint.yaml`
- [ ] T036 Confirm `-Wall` clean: `cabal build all -fno-code 2>&1 | grep -i warning` returns no new warnings introduced by this feature

---

## Dependencies & Execution Order

### Phase Dependencies

```
Phase 1 (Setup)
    └── Phase 2 (Foundational) ← BLOCKS ALL STORIES
            ├── Phase 3  (US1 — Add Account)          🎯 MVP
            ├── Phase 4  (US2 — Inspect Balance)
            ├── Phase 5  (US3 — Send Transaction)
            ├── Phase 6  (US4 — List Addresses)
            ├── Phase 7  (US5 — List All Accounts)
            ├── Phase 8  (US6 — Single-Address Mode Toggle)
            └── Phase 9  (US7 — Consolidate UTXOs)
                        └── Phase 10 (Polish)
```

### Within Phase 2 (Foundational)

```
T002 → T003 → T004 → T005   (Sequential.hs — same file, ordered)
T006 ─────────────────────── (SequentialAny.hs — parallel with T007)
T007 ─────────────────────── (Schema.hs — parallel with T006)
T007 → T008 → T009          (migration chain — ordered)
T007 → T010                 (Store.hs — after schema is defined)
T005 + T010 → T011 → T012   (wallet layer — after types + store)
T013 ──────────────────────── (Types.hs — parallel with T014)
T014 ──────────────────────── (Api.hs — parallel with T013)
T013 + T014 + T012 → T015   (Server.hs stubs — needs all three)
```

### User Story Dependencies

- **US1 (P1)**: Depends on Phase 2 only. No dependency on other stories.
- **US2 (P2)**: Depends on Phase 2 only. T019/T020 parallel with each other.
- **US3 (P3)**: Depends on Phase 2 only. T022 → T023 → T024 sequential within story.
- **US4 (P4)**: Depends on Phase 2 only. Independent of US1–US3.
- **US5 (P5)**: Depends on Phase 2 only. Independent of US1–US4.
- **US6 (P6)**: Depends on Phase 2 only. T037 → T038 (same file) → T039–T043 can largely run after T038.
- **US7 (P7)**: Depends on Phase 2 only. T044 → T045 (same file) → T046–T049.

All user story phases can be worked in parallel once Phase 2 is complete.

---

## Parallel Examples

### Phase 2: Parallel Opportunities

```bash
# After T005 completes, these run in parallel:
Task T006: "mkSeqStateForAccount in SequentialAny.hs"
Task T007: "accountIndex columns in Schema.hs"

# After T007 completes, these run in parallel:
Task T008: "V6.hs migration module"
Task T010: "Store.hs insertPrologue/loadPrologue"

# After T012 completes, these run in parallel:
Task T013: "ApiAccount types in Types.hs"
Task T014: "WalletAccounts routes in Api.hs"
```

### Phase 4: US2 Parallel Opportunities

```bash
# After Phase 2 completes, these run in parallel:
Task T019: "getWalletAccount handler"
Task T020: "getWalletAccountUtxoStatistics handler"
```

### Phase 10: Polish Parallel Opportunities

```bash
# All of these run in parallel after all story phases complete:
Task T030: "deleteWalletAccount handler"
Task T031: "swagger.yaml merge"
Task T032: "Haddock documentation"
Task T050: "US6 integration test"
Task T051: "US7 integration test"
Task T052: "performance check"
Task T034: "Fourmolu formatting"
Task T035: "HLint pass"
# Sequential after all parallel tasks:
Task T053: "end-of-feature regression run"
Task T036: "-Wall clean compile"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (T001–T015) — **critical path**
3. Complete Phase 3: US1 (T016–T018)
4. **STOP and VALIDATE**: `POST /wallets/{id}/accounts` works end-to-end
5. Demo: add account 3H to a live wallet, verify 0H is unaffected

### Incremental Delivery

1. Phase 1 + 2 → foundation ready
2. Phase 3 (US1) → add accounts — testable MVP
3. Phase 4 (US2) → inspect balances — confirms isolation
4. Phase 5 (US3) → send from account — core safety guarantee
5. Phase 6 (US4) → address discovery per account
6. Phase 7 (US5) → list accounts
7. Phase 8 (US6) → single-address mode for hardware wallet users
8. Phase 9 (US7) → consolidation sweep
9. Phase 10 → polish, swagger, Haddock, integration tests (US6+US7), performance check, regression run

### Single-Developer Critical Path

```
T001 → T002 → T003 → T004 → T005 → T007 → T008 → T009 → T010
     → T006 (can be inserted between T005 and T007)
→ T011 → T012 → T013 → T014 → T015
→ T016 → T017 → T018                         (US1 done — first milestone)
→ T019 → T020 → T021                         (US2 done)
→ T022 → T023 → T024 → T025                  (US3 done)
→ T026 → T027                                 (US4 done)
→ T028 → T029                                 (US5 done)
→ T037 → T038 → T039 → T040 → T041 → T043   (US6 done)
→ T044 → T045 → T046 → T047 → T048 → T049   (US7 done)
→ T030, T031, T032, T033, T050, T051, T052, T034, T035 (parallel)
→ T053 → T036                                 (sequential gate)
```

---

## Notes

- `[P]` tasks touch different files or independent concerns — safe to parallelize
- Each user story phase delivers an independently testable increment
- Commit (staged for signing) after each checkpoint
- The `SeqStates` wrapper (T002–T005) is the keystone — all other work depends on it compiling correctly
- The V6 migration (T008) must be verified against an existing wallet DB before merging to avoid data loss
- `-Wall` gate (T036) is the final merge blocker
