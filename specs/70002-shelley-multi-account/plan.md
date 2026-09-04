# Implementation Plan: Shelley Wallet Multi-Account Support

**Branch**: `70002-shelley-multi-account` | **Date**: 2026-08-22 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/70002-shelley-multi-account/spec.md`

## Summary

Add support for multiple hardened accounts (1H, 2H, 3H, …) to existing Shelley wallets. A wallet restored from a mnemonic already has account 0H; new accounts can be added at any valid hardened index (not necessarily sequential). Each account is fully isolated: its own address pools, UTxO set, balance, transaction history, and reward address. The core approach is to introduce a `Map`-keyed wrapper around the existing `SeqState` type (which already has all single-account machinery), extend the DB schema to scope four tables by `accountIndex`, add a DB migration (V5→V6), expose ten new REST endpoints under `/wallets/{id}/accounts` (including a mode-toggle and consolidation endpoint added in scope), add a `SingleExternalAddress` variant to `ChangeAddressMode` for hardware-wallet-compatible single-address accounts, and fix the hardcoded `minBound` account-index assumption in `isOwned` / `mkSeqStateFromRootXPrv`.

---

## Technical Context

**Language/Version**: Haskell (GHC 9.6.x, as pinned in `cabal.project` / Nix flake)  
**Primary Dependencies**: Servant (REST API), Persistent + SQLite (storage), cardano-addresses / cardano-crypto (key derivation), fourmolu (formatting), HLint (static analysis)  
**Storage**: SQLite via Persistent — schema changes are additive column additions + table rebuilds for PK changes, handled by the existing `Migration` framework in `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Migration/`  
**Testing**: `cabal test` per-library; integration tests via local cardano-node cluster (`lib/wallet-e2e/`); HUnit + QuickCheck for unit tests  
**Target Platform**: Linux (musl static), macOS (Intel + Apple Silicon), Windows (cross-compiled) — all via Nix  
**Project Type**: Web service (Servant REST API) backed by a library monorepo  
**Performance Goals**: Account list endpoint returns in < 2 s for a wallet with 20 accounts each holding 500 UTxOs (SC-005 from spec)  
**Constraints**: Zero regression for existing single-account wallet consumers; DB migration must be non-destructive (backfill `accountIndex = 0` for all existing rows); 70-character line limit (Fourmolu); `-Wall` clean  
**Scale/Scope**: Modifying ~10 files across 4 Cabal packages; new migration module; new API types and handlers; swagger.yaml additions

---

## Constitution Check

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Maintenance-First Stability | **PASS** | New accounts are additive; existing single-account behaviour is unchanged. Migration backfills safely. |
| II. Era-Aware Design | **PASS** | Feature is Shelley-era and above; `SeqState` / `ShelleyKey` are already era-parameterised. No Byron/random-scheme tables are touched. |
| III. Type Safety as Security | **PASS** | Account index typed as `Index 'Hardened 'AccountK` throughout. Map keyed at the type level. No `Word32` leaks past the DB boundary. `isOwned` fix removes the explicit single-account assumption. All new public functions will have Haddock. |
| IV. Formal Specification | **PASS** | `specifications/api/swagger.yaml` updated as part of this feature (contract defined in `contracts/api-accounts.yaml`). No Lean proofs affected. |
| V. Reproducible Builds | **PASS** | No new external dependencies; all new code is in existing Cabal packages. |
| VI. Comprehensive Testing | **PASS** | Unit tests for new wallet-layer functions; integration tests for account isolation (funds in 1H don't appear in 0H balance); API-level tests for all 8 new endpoints. |
| VII. Code Quality Gates | **PASS** | Fourmolu + HLint + `-Wall` apply. Must be green before merge. |

No violations — Complexity Tracking section is omitted.

---

## Project Structure

### Documentation (this feature)

```text
specs/70002-shelley-multi-account/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
├── quickstart.md        ← Phase 1 output
├── contracts/
│   └── api-accounts.yaml   ← Phase 1 output (merge target: specifications/api/swagger.yaml)
├── checklists/
│   └── requirements.md
└── tasks.md             ← Phase 2 output (/speckit.tasks — not yet created)
```

### Source Code (affected files)

```text
lib/
├── address-derivation-discovery/
│   └── lib/Cardano/Wallet/Address/
│       ├── Discovery/
│       │   └── Sequential.hs          -- fix isOwned; add SeqStates map wrapper type
│       └── Keys/
│           └── SequentialAny.hs       -- expose accountIndex param in mkSeqStateFromRootXPrv
│
├── wallet/
│   └── src/Cardano/Wallet/
│       ├── DB/
│       │   ├── Sqlite/
│       │   │   ├── Schema.hs          -- add accountIndex to SeqState, SeqStateAddress,
│       │   │   │                         SeqStatePendingIx, TxMeta tables
│       │   │   └── Migration/
│       │   │       ├── New.hs         -- register V6 in migration chain
│       │   │       └── V6.hs          -- NEW: backfill accountIndex = 0, rebuild PKs
│       │   └── Store/
│       │       └── Checkpoints/
│       │           └── Store.hs       -- update insertPrologue / loadPrologue for per-account rows
│       └── Wallet.hs                  -- add addWalletAccount, listWalletAccounts,
│                                         deleteWalletAccount, readAccountUTxO
│
├── api/
│   └── src/Cardano/Wallet/
│       ├── Api.hs                     -- add WalletAccounts routes to Api n
│       ├── Api/
│       │   └── Types.hs               -- add ApiAccount, ApiPostAccount, ApiAccountList
│       └── Api/Http/Shelley/
│           └── Server.hs              -- implement 8 new account handlers
│
└── wallet-e2e/                        -- integration tests for account isolation

specifications/
└── api/
    └── swagger.yaml                   -- merge contracts/api-accounts.yaml schemas + paths
```

**Structure Decision**: Single-project (monorepo) layout — changes span four existing Cabal packages (`address-derivation-discovery`, `wallet`, `api`, `wallet-e2e`). No new packages are introduced.

---

## Implementation Phases

### Phase A — Core Type Layer (no DB, no API)

Goal: introduce the multi-account state type and fix the single-account assumptions. Everything compiles and existing tests pass.

1. **`Sequential.hs`** — introduce `SeqStates n k`:
   ```haskell
   newtype SeqStates n k = SeqStates
       { getSeqStates :: Map (Index 'Hardened 'AccountK) (SeqState n k) }
   ```
   Implement `IsOurs`, `GenChange`, `IsOwned` for `SeqStates` by dispatching to the correct `SeqState` based on which account's pool recognises the address. Fix the `isOwned` "only one account" comment.

2. **`SequentialAny.hs`** — add `mkSeqStateForAccount`:
   ```haskell
   mkSeqStateForAccount
       :: Index 'Hardened 'AccountK
       -> ClearCredentials k
       -> AddressPoolGap
       -> ChangeAddressMode
       -> SeqState n k
   ```
   (wraps `mkSeqStateFromRootXPrv` with an explicit account index instead of `minBound`)

3. **`Wallet.hs`** — add wallet-layer functions:
   - `addWalletAccount    :: WalletId -> Index 'Hardened 'AccountK -> ExceptT ErrNoSuchWallet IO ()`
   - `listWalletAccounts  :: WalletId -> IO [AccountSummary]`
   - `deleteWalletAccount :: WalletId -> Index 'Hardened 'AccountK -> ExceptT ErrDeleteAccount IO ()`
   - `readAccountUTxO     :: WalletId -> Index 'Hardened 'AccountK -> IO UTxO`

### Phase B — DB Schema + Migration

Goal: schema changes land with a safe migration; all existing wallet data survives.

4. **`Schema.hs`** — add `accountIndex Word32` columns with `default 0` to the four tables; update Persistent entity DSL PKs.

5. **`V6.hs`** (new file) — migration logic:
   - `ALTER TABLE … ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0`
   - Rebuild each table with the new PK (rename → create new → copy → drop old)

6. **`New.hs`** — chain `V6.migrateAccounts` as the `5 → 6` step.

7. **`Store/Checkpoints/Store.hs`** — update `insertPrologue` / `loadPrologue` to read/write `accountIndex` in all four tables; queries now filter by `(walletId, accountIndex)`.

### Phase C — REST API

Goal: the eight endpoints are live and tested.

8. **`Api/Types.hs`** — add:
   - `ApiPostAccount { accountIndex :: ApiT DerivationIndex }`
   - `ApiAccount { accountIndex, balance, assets, delegation, rewardAccountKey, addressPoolGap, state, tip }`

9. **`Api.hs`** — add `WalletAccounts` Servant type (10 routes as per `contracts/api-accounts.yaml`), all declared upfront with stub handlers; includes mode-toggle and consolidation routes.

10. **`Server.hs`** — implement handlers; wire coin selection for per-account transactions via `readAccountUTxO`.

11. **`swagger.yaml`** — merge schemas and paths from `contracts/api-accounts.yaml`.

### Phase D — Tests

12. Unit tests for `SeqStates` dispatch logic (address in 1H not recognised by 0H pool).
13. Unit tests for `V6` migration (existing rows get `accountIndex = 0`; new rows use supplied index).
14. Integration tests:
    - Fund account 0H and 1H independently; verify balances are isolated.
    - Construct a TX from 1H; verify inputs are all 1H addresses.
    - Attempt TX from 1H with insufficient funds; verify no fallback to 0H.
    - Verify GET /wallets/{id} aggregate balance = sum of account balances.
15. API contract tests for all 8 new endpoints (happy path + error cases).
