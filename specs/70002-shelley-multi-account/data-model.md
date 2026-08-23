# Data Model: Shelley Wallet Multi-Account Support

**Feature**: 70002-shelley-multi-account  
**Date**: 2026-08-22

---

## Entities

### WalletAccount (new)

Represents one hardened account within a Shelley wallet. A wallet always has at least one account (index 0H). Additional accounts may be added at arbitrary hardened indices.

| Field | Type | Constraints |
|-------|------|-------------|
| `walletId` | `WalletId` | FK → Wallet; NOT NULL |
| `accountIndex` | `Index 'Hardened 'AccountK` | Must be a valid hardened BIP-32 index (0H … 2147483647H); NOT NULL |
| `accountXPub` | `k 'AccountK XPub` | Derived from root key at `m/1852H/1815H/accountIndex`; NOT NULL |
| `rewardAccountKey` | `k 'CredFromKeyK XPub` | Derived at `m/1852H/1815H/accountIndex/2/0`; NOT NULL |
| `createdAt` | `UTCTime` | Wall-clock time the account was added; NOT NULL |

**Primary key**: `(walletId, accountIndex)`  
**Invariants**:
- Account index 0H always exists for the lifetime of the wallet (it is created at wallet creation and cannot be deleted).
- No two accounts within the same wallet may share the same account index.
- `accountXPub` is deterministic: re-derivable from the root key at any time.

---

### SeqState (extended — one row per account)

Previously one row per wallet. Extended to be one row per `(wallet, account)`.

| Field | Type | Change |
|-------|------|--------|
| `walletId` | `WalletId` | PK component (was sole PK) |
| `accountIndex` | `Word32` | **New** PK component; represents the hardened index raw value |
| `externalGap` | `AddressPoolGap` | Unchanged |
| `internalGap` | `AddressPoolGap` | Unchanged |
| `accountXPub` | `ByteString` | Unchanged (serialized XPub) |
| `policyXPub` | `Maybe ByteString` | Unchanged |
| `rewardXPub` | `ByteString` | Unchanged |
| `derivationPrefix` | `DerivationPrefix` | Unchanged (encodes purpose/coinType/accountIndex) |
| `changeAddrMode` | `ChangeAddressMode` | Unchanged |

**Primary key**: `(walletId, accountIndex)`

---

### SeqStateAddress (extended — account-scoped)

Address pool rows are now scoped to a specific account.

| Field | Type | Change |
|-------|------|--------|
| `walletId` | `WalletId` | PK component (unchanged) |
| `accountIndex` | `Word32` | **New** PK component |
| `slot` | `SlotNo` | PK component (unchanged) |
| `address` | `Address` | PK component (unchanged) |
| `index` | `Word32` | Unchanged |
| `role` | `Role` | Unchanged (UtxoExternal / UtxoInternal) |
| `status` | `AddressState` | Unchanged (Used / Unused) |

**Primary key**: `(walletId, accountIndex, slot, address, index, role)`

---

### SeqStatePendingIx (extended — account-scoped)

Pending change address indices are scoped to a specific account.

| Field | Type | Change |
|-------|------|--------|
| `walletId` | `WalletId` | PK component (unchanged) |
| `accountIndex` | `Word32` | **New** PK component |
| `index` | `Word32` | PK component (unchanged) |

**Primary key**: `(walletId, accountIndex, index)`

---

### TxMeta (extended — account-scoped)

Transaction metadata is now scoped to a specific account within a wallet.

| Field | Type | Change |
|-------|------|--------|
| `txId` | `TxId` | PK component (unchanged) |
| `walletId` | `WalletId` | PK component (unchanged) |
| `accountIndex` | `Word32` | **New** PK component; nullable for backward compat during migration |
| `status` | `TxStatus` | Unchanged |
| `direction` | `Direction` | Unchanged |
| `slot` | `SlotNo` | Unchanged |
| … all other fields … | | Unchanged |

**Primary key**: `(txId, walletId, accountIndex)`  
**Migration note**: Existing rows are backfilled with `accountIndex = 0` (representing account 0H).

---

## State Transitions

### Account Lifecycle

```
                 POST /wallets/{id}/accounts
                        │
                        ▼
  [Wallet created]  ──► Account 0H (ACTIVE)
                        │
                        │  address discovery runs (on-chain scan)
                        ▼
                    Account 0H (SYNCED)
                        │
                        │  POST /wallets/{id}/accounts  {account_index: "3H"}
                        ▼
                    Account 3H (ACTIVE, scanning)
                        │
                        │  address discovery completes
                        ▼
                    Account 3H (SYNCED)
                        │
                        │  DELETE /wallets/{id}/accounts/3H
                        ▼
                    Account 3H (DELETED)
```

Account 0H has no transition to DELETED — that transition is permanently blocked.

### Address Discovery State Per Account

Each account independently tracks its own address pool gap window:
- `Unused`: generated but not yet seen on-chain
- `Used`: seen in at least one confirmed transaction

The gap window is maintained independently per account. Discovering a used address in account 1H does not affect the gap window for account 3H.

---

## Validation Rules

- `accountIndex` MUST be a valid hardened index: raw `Word32` value ≥ 2^31 (i.e., 0H = 2147483648, 1H = 2147483649, …)
- Adding an account index that already exists for the wallet MUST return a 409 Conflict.
- Deleting account index 0H MUST return a 403 Forbidden.
- Coin selection for account NH MUST only consider UTxOs whose payment addresses appear in `SeqStateAddress` rows with `(walletId, accountIndex = N)`.
- Change outputs from a transaction on account NH MUST use addresses from `SeqStateAddress` rows with `(walletId, accountIndex = N, role = UtxoInternal)`.

---

## DB Migration: V5 → V6

```sql
-- SeqState: change PK from (walletId) to (walletId, accountIndex)
ALTER TABLE seq_state ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0;
-- Re-create PK (SQLite: requires table rebuild)

-- SeqStateAddress: add accountIndex to PK
ALTER TABLE seq_state_address ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0;
-- Re-create PK

-- SeqStatePendingIx: add accountIndex to PK
ALTER TABLE seq_state_pending_ix ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0;
-- Re-create PK

-- TxMeta: add accountIndex to PK  
ALTER TABLE tx_meta ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0;
-- Re-create PK
```

SQLite does not support `ALTER TABLE ... DROP CONSTRAINT` or `ADD PRIMARY KEY`, so each table must be rebuilt using the rename-create-copy-drop approach, which the existing Persistent migration framework handles.
