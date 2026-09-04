# API Contract: Rescan Endpoints

All existing endpoints are **unchanged**. The following are the only new public-facing additions.

---

## POST /v2/wallets/{wid}/rescan

Reset a single wallet to genesis and force a full re-sync. Use this when a wallet's state is corrupted or incomplete (e.g., addresses were missed during a prior sync).

### Request

```
POST /v2/wallets/{wid}/rescan
Content-Type: application/json

{}
```

Body is empty. No passphrase required — the root key is not re-derived; only the discovery state is reset.

### Response

**202 Accepted**
```json
{}
```

The rescan is asynchronous. The wallet's `state` field in `GET /v2/wallets/{wid}` will show `syncing` with `progress: { quantity: 0, unit: "percent" }` once the reset completes and catch-up begins.

**404 Not Found** — wallet does not exist
**409 Conflict** — wallet is already in a rescan or catch-up

### Behavior

1. Unsubscribes the wallet from the master sync thread.
2. Rolls back the wallet's DB state to genesis (clears UTxO, transaction history, delegation history).
3. Resets address discovery pools to empty (gap resets to wallet's configured gap limit).
4. Starts a catch-up thread from genesis.
5. Returns 202 immediately (does not wait for catch-up to complete).

---

## POST /v2/wallets/resync

Stop the master sync thread and resync **all** wallets from genesis simultaneously. Use this after a software upgrade that introduces new tracked data (e.g., new transaction metadata fields, new address types).

### Request

```
POST /v2/wallets/resync
Content-Type: application/json

{}
```

### Response

**202 Accepted**
```json
{}
```

**409 Conflict** — a resync is already in progress

### Behavior

1. Suspends the master chain sync thread (closes the tip connection to the node).
2. For every registered wallet: unsubscribes, rolls back DB to genesis, resets discovery pools.
3. Starts a single shared catch-up connection that processes all wallets together (same efficiency as normal catch-up but for all wallets simultaneously).
4. When the shared catch-up reaches tip, resumes the master sync thread.
5. Returns 202 immediately.

### Progress

During resync, `GET /v2/wallets/{wid}` returns `state: { status: "syncing", progress: { quantity: N, unit: "percent" } }` for all wallets. The progress reflects the shared catch-up thread's position.

---

## Unchanged Endpoints

All of the following behave identically to their pre-70003 implementations:

- `GET /v2/wallets` — lists wallets with sync state
- `GET /v2/wallets/{wid}` — wallet detail including sync progress
- `POST /v2/wallets` — create wallet (internally starts catch-up thread)
- `DELETE /v2/wallets/{wid}` — delete wallet (internally unsubscribes and cancels catch-up)
- All transaction, address, stake, and key endpoints

The internal sync mechanism change is completely transparent to clients of these endpoints.
