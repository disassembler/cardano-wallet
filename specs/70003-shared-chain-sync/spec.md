# Feature Specification: Shared Master Chain Sync

**Feature Branch**: `70003-shared-chain-sync`
**Created**: 2026-08-25
**Status**: Implemented (2026-08-26) — benchmark results available; global resync (T031/T035) deferred

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Single Node Connection for All Wallets (Priority: P1)

A node operator or power user running cardano-wallet with many wallets currently opens one chain sync connection per wallet. With ten wallets this means ten simultaneous connections to the node, ten independent streams processing every block. As a wallet operator I want all wallets to share a single master chain sync connection so that resource usage scales with the number of blocks, not the number of wallets.

**Why this priority**: This is the foundational change everything else depends on. Without it, adding more wallets or accounts degrades performance linearly. Completing this story alone makes the system meaningfully more efficient at the tip.

**Independent Test**: Start cardano-wallet with three or more wallets. Verify exactly one chain sync connection is open to the node at the tip. Verify all wallet balances and transaction histories remain correct and update when new transactions arrive.

**Acceptance Scenarios**:

1. **Given** three Shelley wallets are loaded, **When** all wallets are fully synced to tip, **Then** only one chain sync connection is active to the node and all three wallets reflect the correct balances.
2. **Given** the master chain sync thread receives a new block, **When** the block contains outputs addressed to multiple wallets, **Then** each wallet's state is updated independently and correctly without re-downloading the block.
3. **Given** the master sync thread receives a rollback signal, **When** the rollback affects a slot range containing transactions from multiple wallets, **Then** all affected wallets roll back their state to the correct prior checkpoint.
4. **Given** a wallet is deleted while the master thread is running, **When** the deletion completes, **Then** that wallet's addresses are removed from the shared address registry and subsequent blocks no longer route updates to it.

---

### User Story 2 - Independent Per-Account Catch-Up Sync (Priority: P2)

A user adds a new wallet or a new account (e.g. account 1H) to an existing wallet. The new wallet or account has no history — it must scan the chain from genesis to discover its addresses and balances. Today this requires the entire wallet to roll back to genesis, disrupting all other accounts. As a user I want only the newly added wallet or account to sync from genesis independently, leaving all other wallets and accounts unaffected.

**Why this priority**: This directly enables the multi-account feature to work correctly. Without independent catch-up, adding account 1H forces account 0H to re-sync from genesis.

**Independent Test**: With one fully-synced wallet (account 0H at tip), add a second account (1H). Verify account 0H's sync state and balances are not disturbed. Verify account 1H begins independently scanning from genesis and eventually reaches tip with correct balances.

**Acceptance Scenarios**:

1. **Given** a wallet with account 0H at tip, **When** account 1H is added, **Then** account 0H's balance and sync progress are unchanged while account 1H begins its catch-up sync independently.
2. **Given** account 1H is mid-catch-up, **When** a new block arrives at tip, **Then** the master thread applies it to account 0H while account 1H's catch-up thread continues processing its own historical blocks.
3. **Given** account 1H's catch-up thread reaches the master thread's current tip, **When** the handoff completes, **Then** the catch-up thread terminates cleanly and account 1H's future updates arrive via the master thread.
4. **Given** a catch-up thread is running, **When** a rollback arrives on the master thread to a point the catch-up has not yet reached, **Then** the catch-up thread handles the coordination correctly without missing or duplicating blocks.

---

### User Story 3 - Per-Account Rescan Without Full Wallet Rollback (Priority: P3)

A user discovers that an account was added after some historical transactions occurred, so its balance is zero even though it should have funds. The user wants to trigger a rescan of just that account from genesis to rediscover its UTxOs, without affecting other accounts or requiring a service restart.

**Why this priority**: Rescan is a recovery operation that depends on the catch-up mechanism from US2. It requires US1 and US2 to be in place first.

**Independent Test**: With a wallet where account 1H has a stale or missing balance, call the rescan endpoint for account 1H. Verify account 0H is not affected. Verify account 1H's address pools are reset and a catch-up thread starts from genesis. Verify account 1H shows the correct balance once the catch-up completes.

**Acceptance Scenarios**:

1. **Given** account 1H has incorrect balance due to a missed historical block range, **When** the user triggers a rescan for account 1H, **Then** account 0H's sync state and balances are unchanged.
2. **Given** a rescan is triggered for account 1H, **When** the rescan starts, **Then** account 1H's address discovery state is reset to empty and a fresh catch-up from genesis begins.
3. **Given** the rescan catch-up completes, **When** account 1H reaches tip, **Then** account 1H shows the correct balance reflecting all historical transactions.
4. **Given** a rescan is triggered, **When** new transactions arrive at tip during the rescan, **Then** they are buffered or replayed correctly so no tip transactions are missed.

---

### Edge Cases

- What happens when the node disconnects while the master thread is running? The master thread must reconnect and all wallets resume from their last known good checkpoint.
- What happens when a catch-up thread and the master thread receive conflicting chain forks? The catch-up thread must defer to the master thread's canonical view.
- What happens when a wallet's address pool is exhausted during catch-up and must be extended? The extended addresses must be registered in the shared address registry immediately so the master thread can route future updates.
- What happens when two accounts in the same wallet are both in catch-up simultaneously? Each runs independently; the master thread handles both at tip regardless.
- What happens if the service is restarted while a catch-up is in progress? On restart the account's sync point is read from the DB and catch-up resumes from that point rather than genesis again.
- What happens when a rollback on the master thread goes further back than the catch-up thread's current position? The catch-up must restart from the rollback point.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST maintain exactly one active chain sync connection to the node for all wallets at the tip, replacing the current one-connection-per-wallet model.
- **FR-002**: System MUST maintain a shared address registry mapping known wallet addresses to their owning wallet and account, updated atomically when wallets or accounts are added or removed.
- **FR-003**: System MUST route each transaction output in a new block to the correct wallet and account using the shared address registry, without re-processing the block per wallet.
- **FR-004**: System MUST coordinate rollback events across all registered wallets, rolling each wallet back to its own nearest valid checkpoint for the rolled-back slot range.
- **FR-005**: System MUST support independent catch-up sync for a newly added wallet or account without stopping or rolling back any other wallet or account.
- **FR-006**: System MUST detect when a catch-up thread has reached the master thread's current tip and perform a clean handoff, terminating the catch-up connection.
- **FR-007**: System MUST register newly discovered addresses (from pool extension during catch-up) into the shared address registry in real time so the master thread can route future blocks.
- **FR-008**: System MUST provide a rescan operation for a single account that resets only that account's address discovery state and starts a fresh catch-up from genesis.
- **FR-009**: System MUST persist each account's catch-up sync point to the database so that a service restart resumes catch-up from the last processed block rather than from genesis.
- **FR-010**: System MUST handle node disconnection by reconnecting the master thread and resuming all wallet state updates from the last known checkpoint.
- **FR-011**: The refactor MUST be entirely transparent to existing REST API clients — all existing endpoints retain identical request/response schemas, status codes, and sync-state semantics. The only new endpoint is a rescan trigger for a specific wallet.
- **FR-012**: System MUST expose a rescan endpoint that resets a specified wallet's address discovery state and forces a full re-sync from genesis, for use when a wallet's state becomes corrupted or incomplete.

### Key Entities

- **Master Sync Thread**: The single long-running thread that maintains the shared node connection at tip and fans out block and rollback events to all registered wallet states.
- **Catch-Up Thread**: A temporary per-wallet-or-account thread that independently replays chain history from genesis (or last checkpoint) to the current tip, then terminates.
- **Shared Address Registry**: A concurrency-safe map from wallet address to (WalletId, AccountIndex) used by the master thread to route discovered outputs. Updated when wallets/accounts are added, removed, or discover new addresses.
- **Wallet Sync State**: Per-wallet, per-account record of the current sync tip, address discovery pools, and UTxO set. Updated by either the master thread (at tip) or the catch-up thread (historical).
- **Handoff Point**: The block height at which a catch-up thread has processed all history up to the master thread's current tip and transfers responsibility to the master thread.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With ten wallets loaded, exactly one chain sync connection to the node is active at the tip (down from ten in the current system).
  - **Evidence (2026-08-26, confirmed 2026-08-26 post-bugfix)**: `chain-sync-flood-bench` confirms single shared connection. Branch peak RSS at N=10: 522 MB vs. master 630 MB (17% less); at N=50: 587 MB vs. 714 MB (18% less). Sync lag identical between branch and master across all N values (0–1 blocks).
- **SC-002**: Adding a new wallet or account triggers no disruption — all other wallets' sync progress and balances remain unchanged during the new account's catch-up.
- **SC-003**: Block processing time at the tip does not increase proportionally with the number of wallets; adding a second wallet adds no more than 10% overhead to per-block processing compared to a single wallet.
  - **Evidence (2026-08-26, confirmed 2026-08-26 post-bugfix)**: Benchmark shows RSS growth from N=1 to N=50 is 70 MB on the branch (13%) vs. 92 MB on master (15%); block lag remains 0–1 blocks on both branches across all N, confirming processing overhead does not scale with wallet count.
- **SC-004**: A per-account rescan completes and shows correct balances without requiring a service restart or affecting sibling accounts.
- **SC-005**: After a node disconnection, all wallets resume syncing automatically within 30 seconds of reconnection with no data loss.
- **SC-006**: A catch-up thread's handoff to the master thread produces no gaps — every block processed by the master thread during catch-up is correctly accounted for in the account's final state.

## Assumptions

- **This is a transparent internal refactor.** Existing API clients (wallets, applications, integrations) must observe no behavioral change beyond improved performance and reduced resource usage. The only new public-facing change is a rescan endpoint for forced wallet reset.
- The cardano-node's local socket accepts multiple simultaneous connections; catch-up threads use their own connections while the master thread holds the tip connection.
- Wallet address pools are extended deterministically from the account's key material, so newly discovered addresses during catch-up can be registered into the shared registry without re-deriving from the root key each time.
- The existing `ChainFollower` callback interface and `mapChainFollower` primitive are sufficient to adapt individual wallet update logic to the shared fan-out model without rewriting wallet state management.
- Rollback depth is bounded by the security parameter (2160 blocks on mainnet); catch-up threads do not need to handle unbounded rollbacks.
- The rescan operation is expected to take minutes to hours depending on chain length; no real-time progress reporting is required in v1.
- Shared wallet state (the `Wallet s` checkpoint and per-account SeqState) remains per-wallet in the database; the shared address registry is in-memory only and rebuilt on startup from the persisted wallet states.
- Byron-era wallets and Shared (multisig) wallets are out of scope for this feature; the shared sync architecture targets Shelley sequential wallets only in v1.
