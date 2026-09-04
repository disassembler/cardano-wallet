# Research: Shelley Wallet Multi-Account Support

**Feature**: 70002-shelley-multi-account  
**Date**: 2026-08-22  
**Status**: Complete — all unknowns resolved

---

## Finding 1: SeqState is Explicitly Single-Account by Design

**Decision**: A new `Map`-keyed wrapper around `SeqState` is the correct extension point — not modifying `SeqState` itself.

**Rationale**: `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs` line ~33 contains an explicit comment: *"The management of accounts is left-out for this implementation focuses on a single account. In practice, one wants to manage a set of pools, one per account."* The `SeqState` data type already has all the machinery for a single account (`accountXPub`, `internalPool`, `externalPool`, `pendingChangeIxs`, `derivationPrefix`). Multi-account support means managing a `Map (Index 'Hardened 'AccountK) (SeqState n k)` at the layer above.

**Alternatives considered**:
- Modifying `SeqState` to hold multiple accounts internally — rejected; would require changing all existing `SeqState` consumers and violates the single-responsibility of the type.
- A new discriminated union type — rejected; unnecessary complexity when a simple Map suffices.

---

## Finding 2: Account Key Derivation Already Supports Arbitrary Indices

**Decision**: No new derivation machinery needed. `deriveAccountPrivateKey` in `Cardano/Wallet/Address/Derivation/Shelley.hs` already accepts any `Index 'Hardened 'AccountK`.

**Rationale**: The function signature is:
```haskell
deriveAccountPrivateKey
    :: Passphrase "encryption"
    -> k 'RootK XPrv
    -> Index 'Hardened 'AccountK
    -> k 'AccountK XPrv
```
Only the call site in `mkSeqStateFromRootXPrv` is hardcoded to `minBound` (account 0H). Adding a new account requires calling this function with the desired `Index 'Hardened 'AccountK`.

**Alternatives considered**: None — derivation path is well-defined by CIP-1852.

---

## Finding 3: `isOwned` Has an Explicit Single-Account Assumption That Must Be Fixed

**Decision**: The `isOwned` implementation in `Sequential.hs` line ~606 carries a comment "We are assuming there is only one account." This function must be updated when multi-account `SeqState` wrappers are introduced.

**Rationale**: `isOwned` takes a root private key, an address, and the current state, and returns the private key for that address if it belongs to the wallet. With multiple accounts, it must iterate over all account states to find which account (if any) owns the address, then derive the correct private key for that account.

---

## Finding 4: DB Schema Requires Four Table Changes

**Decision**: Add `accountIndex (Word32)` as a primary key component to `SeqState`, `SeqStateAddress`, and `SeqStatePendingIx` tables. Add a nullable `txMetaAccountIndex (Maybe Word32)` to `TxMeta` for backward compatibility.

**Rationale** (per `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Schema.hs`):

| Table | Current PK | New PK | Change |
|-------|-----------|--------|--------|
| `SeqState` | `(walletId)` | `(walletId, accountIndex)` | One row per account |
| `SeqStateAddress` | `(walletId, slot, address, index, role)` | `(walletId, accountIndex, slot, address, index, role)` | Addresses scoped to account |
| `SeqStatePendingIx` | `(walletId, ix)` | `(walletId, accountIndex, ix)` | Pending indexes scoped to account |
| `TxMeta` | `(txId, walletId)` | `(txId, walletId, accountIndex)` | TX scoped to account |

The `Checkpoint` and `UTxO` tables remain wallet-scoped. UTxO-to-account membership is deterministic from the owning address, which is already in `SeqStateAddress` with its account index.

**Alternatives considered**:
- Storing all accounts in a CBOR blob per wallet — rejected; breaks the delta-store pattern, kills queryability, and makes migrations harder.
- Adding `accountIndex` to `UTxO` directly — deferred; derivable from `SeqStateAddress` join. Can be added as an optimisation later if query performance requires it.

---

## Finding 5: Migration is Version 5 → 6 in the New-Style Framework

**Decision**: Implement a new `V6.migrateAccounts` migration module following the existing pattern in `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Migration/New.hs`.

**Rationale**: The migration framework uses type-level `Nat` versions and a chain of `Migration m from to` arrows. The current chain ends at version 5. The new migration adds `accountIndex` columns to the four tables, backfills existing rows with `0` (representing account 0H), and updates the primary key constraints.

---

## Finding 6: API Layer Follows an Established Servant Sub-Resource Pattern

**Decision**: New endpoints are added under a new `WalletAccounts` type alias in `lib/api/src/Cardano/Wallet/Api.hs`, following the existing `WalletKeys` / `Addresses` pattern.

**Rationale**: Existing shared wallets (`ApiActiveSharedWallet`) already have an `accountIndex :: ApiT DerivationIndex` field and use `derivationSegment` in swagger. New endpoints use `Capture "accountIndex" (ApiT DerivationIndex)` for the path segment — the `DerivationIndex` type already handles `FromHttpApiData` parsing including the `H` suffix.

**New endpoint structure**:
```
POST   /wallets/{walletId}/accounts                   -- add account by index in body
GET    /wallets/{walletId}/accounts                   -- list all accounts
GET    /wallets/{walletId}/accounts/{accountIndex}    -- get one account
DELETE /wallets/{walletId}/accounts/{accountIndex}    -- remove account (not 0H)
GET    /wallets/{walletId}/accounts/{accountIndex}/addresses
GET    /wallets/{walletId}/accounts/{accountIndex}/utxo/statistics
POST   /wallets/{walletId}/accounts/{accountIndex}/transactions
GET    /wallets/{walletId}/accounts/{accountIndex}/transactions
```

---

## Finding 7: Coin Selection Pipeline Operates on a Pre-Filtered UTxO Set

**Decision**: Per-account coin selection is implemented by filtering the wallet's UTxO set to only those outputs whose addresses belong to the target account before passing to the existing `buildTransaction` / `buildCoinSelectionForTransaction` functions.

**Rationale**: `readWalletUTxO` in `Cardano/Wallet.hs` returns the full wallet UTxO. By introducing a new `readAccountUTxO :: AccountIx -> WalletLayer IO s -> IO UTxO` that filters by account membership (via `IsOurs` on the specific account's `SeqState`), the existing coin selection code needs no changes. The filter is a single `Map.filter` over the UTxO set keyed by which `SeqState` owns each address.

---

## Finding 8: Reward Accounts Are Per-Account (CIP-1852)

**Decision**: Each account index NH has its own reward/staking address derived at `m/1852H/1815H/NH/2/0`. Delegation and rewards are independent per account. This is already how `rewardAccountKey` is stored in each `SeqState` — it just needs to be surfaced per-account in the API.

---

## Finding 9: `GetWallet` Aggregate Balance Stays Correct

**Decision**: The existing `GET /wallets/{walletId}` endpoint's balance field becomes the **sum** of all account balances. This is implemented by summing across all `SeqState` entries for the wallet when constructing the `ApiWallet` response.

**Rationale**: No breaking change to existing consumers. Single-account wallets (0H only) return the same value as before. Multi-account wallets aggregate transparently.

---

## Finding 10: `ChangeAddressMode` Partially Covers Single-Address, But Not to the External Chain

**Decision**: Add a third `ChangeAddressMode` variant — `SingleExternalAddress` — to `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery.hs`. Add one case to `genChange` in `Sequential.hs` that uses `UtxoExternal` role at index 0.

**Rationale**: Two variants exist today: `SingleChangeAddress` (always `/1/0` — internal chain, index 0) and `IncreasingChangeAddresses` (incrementing `/1/N`). Neither satisfies the hardware wallet requirement of change going to `/0/0` (external chain). The new `SingleExternalAddress` variant routes `genChange` to `UtxoExternal` at `minBound`, skipping the internal pool entirely. The existing `changeAddrMode` column in the `SeqState` table stores this value — **no schema change needed for this feature**.

**Alternatives considered**:
- Repurpose `SingleChangeAddress` to use the external chain — rejected; breaking change for existing users of that mode.
- A separate boolean flag `singleAddressMode` on the account — rejected; `ChangeAddressMode` is the correct abstraction and is already persisted.

---

## Finding 11: Consolidation is a Self-Payment Transaction with a Select-All Coin Selection Strategy

**Decision**: The consolidation endpoint reuses the existing transaction construction pipeline with a custom "select all" coin selection override: gather all UTXOs for the account, set the single output to `(/0/0, totalInput - fee)`, and sign+submit normally.

**Rationale**: The existing `buildTransaction` / sign / submit pipeline already handles everything except the selection strategy. The only new logic is selecting all UTXOs rather than just enough to cover a target amount. The target address is always `deriveAddressPublicKey accountXPub UtxoExternal minBound` (i.e., `/0/0`). When UTXOs exceed maximum transaction size, the strategy selects the largest batch that fits within size/fee limits and the response includes `"complete": false` to prompt a follow-up call.

**Alternatives considered**:
- A background sweep process — rejected; caller-initiated is simpler, safer, and matches the user's intent.
- Reusing `POST /transactions` with explicit input specification — rejected; requires the caller to enumerate all UTXOs and is error-prone.

---

## Summary of Key Files to Modify

| File | What Changes |
|------|-------------|
| `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery.hs` | Add `SingleExternalAddress` variant to `ChangeAddressMode` |
| `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Discovery/Sequential.hs` | Fix `isOwned` multi-account comment; introduce `SeqStates` map wrapper; add `SingleExternalAddress` case in `genChange` |
| `lib/address-derivation-discovery/lib/Cardano/Wallet/Address/Keys/SequentialAny.hs` | `mkSeqStateFromRootXPrv` — expose account index parameter |
| `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Schema.hs` | Add `accountIndex` to SeqState, SeqStateAddress, SeqStatePendingIx, TxMeta |
| `lib/wallet/src/Cardano/Wallet/DB/Store/Checkpoints/Store.hs` | Update insert/load logic for per-account SeqState rows |
| `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Migration/New.hs` | Add V6 migration entry |
| `lib/wallet/src/Cardano/Wallet/DB/Sqlite/Migration/V6.hs` | New file: add accountIndex columns, backfill with 0 |
| `lib/wallet/src/Cardano/Wallet.hs` | Add `readAccountUTxO`, `addWalletAccount`, `listWalletAccounts`, `deleteWalletAccount`, `setAccountMode`, `consolidateAccountUtxo` |
| `lib/api/src/Cardano/Wallet/Api.hs` | Add `WalletAccounts` routes to `Api n` |
| `lib/api/src/Cardano/Wallet/Api/Types.hs` | Add `ApiAccount`, `ApiAccountSummary`, `ApiPostAccount`, `ApiAccountMode`, `ApiConsolidateResponse` types |
| `lib/api/src/Cardano/Wallet/Api/Http/Shelley/Server.hs` | Implement all account handlers including mode toggle and consolidation |
| `specifications/api/swagger.yaml` | Add account sub-resource schemas and paths |
