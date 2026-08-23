# Feature Specification: Shelley Wallet Multi-Account Support

**Feature Branch**: `70002-shelley-multi-account`  
**Created**: 2026-08-22  
**Status**: Draft  
**Input**: User description: "Shelley wallet multi-account support. A user has already imported a mnemonic for a Shelley wallet which creates account index 0H by default. Add an API endpoint to add additional accounts (1H, 2H, 3H, etc.) to an existing Shelley wallet. Each account must be tracked independently with its own UTXO set, address discovery, balance, and transaction history. There must be ZERO cross-account UTXO coin selection or signing — each account is treated as a fully independent wallet."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Add a New Account to an Existing Wallet (Priority: P1)

A wallet owner has restored a Shelley wallet from mnemonic (which automatically creates account 0H). They want to add account 1H to that same wallet to organize funds separately — for example, to keep personal and business funds under one mnemonic without any possible mixing.

**Why this priority**: This is the core capability being delivered. Without it, no other multi-account functionality is useful.

**Independent Test**: Can be fully tested by calling the add-account endpoint on an existing wallet and verifying a new account entry is returned with the correct index and a fresh, empty balance.

**Acceptance Scenarios**:

1. **Given** a Shelley wallet exists with only account 0H, **When** a user calls the add-account endpoint, **Then** account 1H is created with a fresh address discovery state, zero balance, and no UTXOs.
2. **Given** a wallet with only account 0H, **When** a user calls add-account with index 3H, **Then** account 3H is created directly — intermediate indices 1H and 2H are not required and not created.
3. **Given** a wallet that already has N accounts, **When** a user retrieves the account list, **Then** all N accounts are returned with their respective indices, balances, and statuses.
4. **Given** an invalid wallet ID, **When** a user calls add-account, **Then** a clear error is returned indicating the wallet was not found.

---

### User Story 2 - Inspect an Account's Balance and UTXOs (Priority: P2)

A wallet owner wants to view the balance and UTXO set for a specific account (e.g., account 2H) without seeing funds from other accounts mixed in.

**Why this priority**: Isolation of funds is only verifiable once accounts can be inspected individually. This enables the user to confirm that each account behaves as an independent wallet.

**Independent Test**: Can be tested by funding account 1H on a test network, then querying the account detail endpoint and verifying only account 1H's UTXOs appear — account 0H's UTXOs must not appear.

**Acceptance Scenarios**:

1. **Given** accounts 0H and 1H exist, and 1H has received funds, **When** the user requests the balance for account 1H, **Then** only 1H's balance is returned (0H's funds are excluded).
2. **Given** account 2H has never received any funds, **When** the user queries account 2H's UTXOs, **Then** an empty UTXO set and zero balance are returned.
3. **Given** a transaction is sent to an address belonging to account 1H, **When** the account's transaction history is queried, **Then** that transaction appears only in account 1H's history, not in account 0H's history.

---

### User Story 3 - Send a Transaction from a Specific Account (Priority: P3)

A wallet owner wants to send funds from account 1H specifically, and requires that only UTXOs owned by account 1H are used — coins from account 0H must never be touched.

**Why this priority**: Strict isolation of coin selection is the primary safety guarantee of this feature. A user trusting account separation for organizational or compliance reasons must be able to rely on it completely.

**Independent Test**: Can be tested by funding both 0H and 1H, constructing a transaction from account 1H, and verifying that the resulting transaction only contains inputs whose addresses are derived from account 1H.

**Acceptance Scenarios**:

1. **Given** accounts 0H and 1H both have funds, **When** a transaction is constructed from account 1H, **Then** all inputs in the resulting transaction are addresses derived from account 1H's derivation path.
2. **Given** account 1H has insufficient funds to cover a transaction, **When** the user attempts to send from account 1H, **Then** an error is returned — the system does NOT fall back to account 0H's UTXOs.
3. **Given** a transaction is signed and submitted from account 1H, **When** the transaction is confirmed on-chain, **Then** account 1H's balance decreases, and account 0H's balance is unchanged.
4. **Given** a transaction from account 1H has change and account 1H is in `hd` mode, **When** the transaction is constructed, **Then** the change output address is derived from account 1H's internal (change) address pool (`/1/N`), not from any other account. If account 1H is in `single_address` mode, the change output goes to account 1H's `/0/0` address instead (per FR-016).

---

### User Story 4 - List Addresses for a Specific Account (Priority: P4)

A wallet owner wants to generate and retrieve receiving addresses that belong specifically to account 2H, so they can share those addresses for deposits to that account only.

**Why this priority**: Address generation per account is required for the user to direct inbound funds to a specific account.

**Independent Test**: Can be tested by requesting the address list for account 2H and verifying all returned addresses decode to derivation paths of the form `1852H/1815H/2H/0/N`.

**Acceptance Scenarios**:

1. **Given** account 2H exists, **When** the user lists addresses for account 2H, **Then** all returned addresses follow the derivation path `1852H/1815H/2H/role/index`.
2. **Given** account 2H has no used addresses, **When** the user requests unused external addresses for account 2H, **Then** at least one fresh external address is returned.
3. **Given** account 1H and account 2H both exist, **When** addresses are listed for each account separately, **Then** no address appears in both lists.

---

### User Story 5 - List All Accounts for a Wallet (Priority: P5)

A wallet owner wants to see all the accounts that have been created under a Shelley wallet, along with their balances and indices.

**Why this priority**: Discoverability is required for managing multiple accounts over time.

**Independent Test**: Can be tested by creating a wallet with 3 accounts and confirming the list endpoint returns exactly 3 accounts with correct indices (0H, 1H, 2H).

**Acceptance Scenarios**:

1. **Given** a newly restored wallet, **When** the user lists accounts, **Then** exactly one account (0H) is returned.
2. **Given** a wallet with accounts 0H, 1H, and 2H, **When** the user lists accounts, **Then** three accounts are returned in ascending index order.
3. **Given** each account has a different balance, **When** accounts are listed, **Then** each account's balance is reported independently and their sum equals the total wallet balance.

---

### User Story 6 — Toggle Single-Address Mode for an Account (Priority: P6)

A hardware wallet user (Ledger, Trezor) wants the wallet backend to never derive internal (change) chain addresses for a given account. All funds — both received and change from outgoing transactions — should always return to the account's first external address (`m/1852H/1815H/NH/0/0`). This mirrors how hardware wallets behave natively.

**Why this priority**: Hardware wallet users rely on this to keep their on-chain footprint minimal and avoid surprising internal-chain address derivation. Accounts default to HD (increasing change) mode; this is an opt-in toggle.

**Independent Test**: Toggle account 1H to single-address mode, send a transaction, and verify the change output address equals the account's `/0/0` address — not any `/1/N` address.

**Acceptance Scenarios**:

1. **Given** account 1H is in default HD mode, **When** the user calls the mode-toggle endpoint with `single_address`, **Then** account 1H's mode is updated and subsequent transactions send change to `/0/0`.
2. **Given** account 1H is in single-address mode, **When** the user calls the mode-toggle endpoint with `hd`, **Then** account 1H reverts to standard increasing-change-address behaviour.
3. **Given** account 1H is in single-address mode and the user constructs a transaction, **Then** the change output address is the external `/0/0` address — no `/1/N` key is ever derived or used.
4. **Given** account 0H (the default), **When** the user toggles it to single-address mode, **Then** it behaves identically to any other account in single-address mode.

---

### User Story 7 — Consolidate Account UTXOs to Single Address (Priority: P7)

A user wants to sweep all UTXOs in an account into a single UTXO at `/0/0`, reducing fragmentation and simplifying the on-chain footprint. This is especially useful before or after switching to single-address mode.

**Why this priority**: After importing a previously active HD wallet, the user may have many small UTXOs scattered across derived addresses. Consolidation produces a single clean UTXO at the canonical single address. This is a one-shot caller-initiated operation, not a background process.

**Independent Test**: Fund account 2H with UTXOs at several different derived addresses, call the consolidate endpoint with the correct passphrase, and verify exactly one confirmed UTXO exists at `/0/0` afterwards.

**Acceptance Scenarios**:

1. **Given** account 2H has UTXOs at `/0/0`, `/0/3`, and `/0/7`, **When** the user calls the consolidate endpoint, **Then** a single transaction is constructed with all three UTXOs as inputs and a single output at `/0/0` (minus fees).
2. **Given** the account has only one UTXO already at `/0/0`, **When** the user calls consolidate, **Then** the system returns an informational response indicating no consolidation is needed and no transaction is constructed.
3. **Given** the passphrase is incorrect, **When** the user calls consolidate, **Then** a 403 is returned and no transaction is broadcast.
4. **Given** the account has more UTXOs than fit in a single valid transaction, **When** the user calls consolidate, **Then** the system constructs the largest valid consolidation transaction it can and indicates in the response that further calls may be needed to complete consolidation.

---

### Edge Cases

- What happens when a user tries to add an account index that already exists? The system must return an error indicating the account already exists rather than silently overwriting it.
- What happens when a user tries to add an account past the maximum valid hardened index (2147483647H)? The system must reject it with a clear out-of-range error.
- What happens when account 0H is requested for deletion? The system must reject the request — account 0H is the default account and cannot be removed.
- What happens if the wallet's passphrase is required to sign a transaction from account N? Passphrase-based signing must work per-account the same way it works today for the single-account case.
- What happens if a user queries an account index that has not been added? The system must return a 404-equivalent error, not silently create the account.
- What happens when a user's node is syncing and account balances are stale? Per-account balances carry the same sync-progress caveat as the current wallet balance — the response should indicate sync status.
- How are accounts handled during wallet restoration from a mnemonic that previously had multiple accounts? The system restores account 0H only; additional accounts must be re-added manually and will rediscover their UTXOs via on-chain scanning.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide an endpoint to add a specific hardened account index to an existing Shelley wallet; the caller specifies the desired index (e.g., 1H, 3H, 5H) and the system creates that account regardless of whether intermediate indices exist.
- **FR-002**: The system MUST maintain a completely independent address discovery state for each account, including separate external (receiving) and internal (change) address pools.
- **FR-003**: The system MUST maintain a completely independent UTXO set for each account; a UTXO belonging to account NH must never appear in the UTXO set of account MH (N ≠ M).
- **FR-004**: The system MUST provide an endpoint to list all accounts associated with a Shelley wallet, returning each account's index and current balance.
- **FR-005**: The system MUST provide an endpoint to retrieve the details of a specific account (balance, UTXO statistics, address discovery progress).
- **FR-006**: The system MUST provide an endpoint to list addresses (used and unused) scoped to a specific account.
- **FR-007**: The system MUST provide an endpoint to construct and submit a transaction from a specific account; coin selection MUST be restricted exclusively to UTXOs belonging to that account.
- **FR-008**: The system MUST ensure that change outputs from a transaction on account NH are always assigned to addresses derived from account NH — never from another account. In `hd` mode this means internal-chain addresses (`/1/N`); in `single_address` mode this means the external `/0/0` address (per FR-016). In no case may change go to a different account.
- **FR-009**: The system MUST reject any request to delete or remove account 0H; it is the default account and is permanent for the lifetime of the wallet.
- **FR-010**: The system MUST continue to serve all existing wallet endpoints (balance, addresses, transactions, coin selection) against account 0H without any change in behavior, preserving full backward compatibility.
- **FR-011**: The system MUST reject a transaction construction request for account NH when account NH has insufficient funds, and MUST NOT attempt to supplement from other accounts.
- **FR-012**: The system MUST scope transaction history per account; a transaction that only touches account 1H's addresses must appear only in account 1H's history.
- **FR-013**: The system MUST derive each account's keys from the wallet's root key using the standard derivation path `m/1852H/1815H/NH` where N is the account index.
- **FR-014**: The system MUST report the wallet's aggregate balance as the sum of all its accounts' balances.
- **FR-015**: The system MUST provide an endpoint to toggle any account (including 0H) between `hd` mode (increasing change addresses on the internal chain) and `single_address` mode (change always routed to the account's external `/0/0` address; no internal-chain keys are ever derived or used).
- **FR-016**: When an account is in `single_address` mode, the system MUST ensure that transaction construction never derives or uses any key on the internal derivation path (`m/1852H/1815H/NH/1/N`).
- **FR-017**: The system MUST provide a consolidation endpoint that constructs and submits a transaction spending all UTXOs for an account into a single output at the account's external `/0/0` address.
- **FR-018**: The consolidation endpoint MUST require the wallet's spending passphrase; it MUST return an error without broadcasting if the passphrase is incorrect.
- **FR-019**: If the account already has exactly one UTXO located at `/0/0`, the consolidation endpoint MUST return a success response indicating no action was taken, without constructing a transaction.
- **FR-020**: If the number of UTXOs exceeds what fits in a single valid transaction, the consolidation endpoint MUST consolidate as many as possible in one transaction and indicate in the response that the caller should invoke the endpoint again to continue.

### Key Entities

- **Wallet**: Identified by a wallet ID. Owns one mnemonic (root key) and one or more accounts. Existing entity extended to reference multiple accounts.
- **Account**: A hardened account index (NH) within a wallet. Has its own address discovery state, UTXO set, balance, and transaction history. Derived via `m/1852H/1815H/NH`. The account index is immutable once created.
- **Account Address Pool**: A collection of derived addresses for a specific account and role (external/internal). Each pool belongs to exactly one account.
- **Account UTXO**: An unspent transaction output whose address is derived from a specific account. Scoped exclusively to that account.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can add a new account to an existing Shelley wallet in a single API call, and the account is immediately queryable for its (empty) balance and addresses.
- **SC-002**: A transaction constructed from account NH contains only inputs whose addresses belong to account NH — verifiable by decoding each input address and checking its derivation path prefix.
- **SC-003**: Funding account 1H on a test network and querying account 0H's balance returns zero change — confirming 100% UTXO isolation between accounts.
- **SC-004**: Restoring a wallet from a mnemonic that previously had 3 accounts results in account 0H being available immediately; after manually re-adding accounts 1H and 2H, all three accounts successfully rediscover their on-chain UTXOs independently.
- **SC-005**: The account list endpoint returns results in under 2 seconds for a wallet with up to 20 accounts, each having up to 500 UTXOs.
- **SC-006**: All existing single-account wallet API calls (balance, addresses, transactions) continue to function identically without modification — zero regression for current users.
- **SC-007**: A user cannot accidentally combine funds from two accounts: constructing a transaction that would require inputs from two accounts returns an error, not a partially-signed transaction.
- **SC-008**: After toggling an account to single-address mode, every transaction's change output uses the external `/0/0` address — verified by inspecting transaction outputs on a test network; no `/1/N` address ever appears.
- **SC-009**: After calling the consolidation endpoint on an account with N UTXOs spread across multiple derived addresses, the account has exactly one UTXO at `/0/0` (assuming N fits in a single transaction); calling consolidate again returns "no action needed".

## Assumptions

- **Account creation is arbitrary**: Users may add any valid hardened account index in any order. Creating account 5H does not require first creating 1H–4H. Each added account is tracked independently regardless of gaps in the index space.
- **Account 0H is always present**: Restoring a wallet from a mnemonic always creates account 0H. It cannot be deleted.
- **Restoration is account-0H-only by default**: When a wallet is restored from a mnemonic, only account 0H is restored. Additional accounts previously in use must be re-added explicitly, at which point on-chain address discovery runs for each.
- **Passphrase applies wallet-wide**: The wallet's spending passphrase (if set) is used to unlock signing for any account. There are no per-account passphrases.
- **Staking is per-account**: Each account has its own reward address (derived from `m/1852H/1815H/NH/2/0`). Delegation and rewards are independent per account.
- **No cross-account aggregated coin selection endpoint**: There is no planned endpoint to construct a transaction that draws from multiple accounts simultaneously. Each transaction is strictly single-account.
- **Existing wallets are unaffected**: Wallets created before this feature is deployed continue to work exactly as before. No migration or data change is required for existing single-account wallets.
- **Maximum accounts**: No artificial low cap is enforced in this feature; the upper bound is the maximum valid hardened index. Practical use is expected to be single-digit account counts.
