# API Contract: POST /v2/wallets/{walletId}/rescan

**Branch**: `70004-resync-endpoint` | **Date**: 2026-09-01

Force a specific wallet to re-index from genesis. Use when automatic chain continuity recovery cannot find a valid intersection, or when a full re-index is desired. Key material and wallet metadata are preserved; only derived chain state is cleared.

---

## Endpoint

```
POST /v2/wallets/{walletId}/rescan
Content-Type: application/json
```

### Path Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `walletId` | string (40 hex chars) | Yes | The wallet ID to rescan |

### Request Body

Empty JSON object. No passphrase is required — the root key is not re-derived; only the discovery state is reset.

```json
{}
```

---

## Responses

### 202 Accepted

The rescan has been initiated. The operation is asynchronous — the response is returned immediately; the actual reset and re-sync happen in the background.

```json
{}
```

After receiving 202, clients should poll `GET /v2/wallets/{walletId}` to track rescan progress via the `state` field.

---

### 404 Not Found

The wallet ID does not exist.

```json
{
  "code": "no_such_wallet",
  "message": "I couldn't find a wallet with the given id: {walletId}"
}
```

---

### 409 Conflict

A rescan is already in progress for this wallet. The in-progress rescan is not interrupted.

```json
{
  "code": "rescan_already_running",
  "message": "A rescan is already in progress for wallet {walletId}. Wait for it to complete before requesting another."
}
```

---

## Behaviour

1. Validates the wallet ID exists — 404 if not.
2. Checks whether a rescan is already running — 409 if so.
3. Sets the rescan-in-progress flag atomically.
4. Returns 202 immediately.
5. In the background:
   a. Stops the wallet worker if running.
   b. Rolls back all wallet DB state (UTxO, transaction history, delegation history) to genesis via `rollbackTo Origin`.
   c. Resets the address discovery pool to its initial state (gap resets to the wallet's configured gap limit; discovered addresses cleared).
   d. Restarts the wallet worker; chain following resumes from genesis.
   e. Clears the rescan-in-progress flag once the worker successfully begins applying blocks.

---

## Progress Observation

While rescanning, `GET /v2/wallets/{walletId}` returns:

```json
{
  "id": "{walletId}",
  "state": {
    "status": "syncing",
    "progress": {
      "quantity": 0,
      "unit": "percent"
    }
  }
}
```

Progress increases as the wallet catches up from genesis. The wallet is considered fully synced when `state.status` is `"ready"`.

---

## What Is Preserved

| Data | Preserved? |
|------|-----------|
| Root private key / key material | Yes |
| Wallet name | Yes |
| Passphrase hash | Yes |
| Gap limit configuration | Yes |
| UTxO set | No — rebuilt during rescan |
| Transaction history | No — rebuilt during rescan |
| Delegation history | No — rebuilt during rescan |
| Address discovery state | No — reset to initial gap state |

---

## Unchanged Endpoints

All existing endpoints behave identically. This is a purely additive change.

- `GET /v2/wallets` — continues to list the wallet (with `state: syncing` during rescan)
- `GET /v2/wallets/{wid}` — returns sync progress
- `DELETE /v2/wallets/{wid}` — still available during rescan if the user prefers deletion
- All transaction, address, stake, and key endpoints — behaviour unchanged for wallets not undergoing rescan
