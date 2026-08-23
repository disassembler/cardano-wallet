{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Copyright: © 2026 IOHK
-- License: Apache-2.0
--
-- Database schema migration V5 → V6.
--
-- Adds an @account_index@ column (NOT NULL DEFAULT 0) to the four tables that
-- are scoped to sequential-scheme address discovery:
--
--   * @seq_state@         — PK was @(wallet_id)@,              now @(wallet_id, account_index)@
--   * @seq_state_address@ — adds column only (retains auto-id PK)
--   * @seq_state_pending@ — PK was @(wallet_id, pending_ix)@,  now @(wallet_id, account_index, pending_ix)@
--   * @tx_meta@           — PK was @(tx_id, wallet_id)@,       now @(tx_id, wallet_id, account_index)@
--
-- All existing rows are backfilled with @account_index = 0@, preserving the
-- semantics of the original single-account design.
--
-- Note: @seq_state_address@ uses an auto-increment @id@ primary key in the
-- Persistent entity definition (the @Primary@ declaration spans multiple lines
-- and is silently ignored by the persistent quasi-quoter). The table is
-- therefore NOT rebuilt here — only @account_index@ is added as a column.
module Cardano.Wallet.DB.Sqlite.Migration.V6
    ( migrateAccounts
    ) where

import Cardano.DB.Sqlite
    ( ReadDBHandle
    , dbConn
    )
import Cardano.Wallet.DB.Migration
    ( Migration
    , mkMigration
    )
import Control.Monad
    ( void
    )
import Control.Monad.Reader
    ( ReaderT (..)
    )
import Data.Text
    ( Text
    )
import Prelude

import qualified Database.Sqlite as Sqlite

-- | Migration from schema version 5 to 6.
migrateAccounts :: Migration (ReadDBHandle IO) 5 6
migrateAccounts = mkMigration $ ReaderT $ \db -> void $ do
    let conn = dbConn db
    addAccountIndexColumn conn "seq_state"
    rebuildSeqState conn
    addAccountIndexColumn conn "seq_state_address"
    -- seq_state_address is NOT rebuilt: its Persistent entity uses an
    -- auto-increment id PK (the multi-line Primary declaration is ignored
    -- by the quasi-quoter), so the id column must be preserved.
    addAccountIndexColumn conn "seq_state_pending"
    rebuildSeqStatePending conn
    addAccountIndexColumn conn "tx_meta"
    rebuildTxMeta conn

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

exec :: Sqlite.Connection -> Text -> IO ()
exec conn q = do
    stmt <- Sqlite.prepare conn q
    _ <- Sqlite.step stmt
    Sqlite.finalize stmt

-- | ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0 to the given table.
-- SQLite does not allow adding a NOT NULL column without a DEFAULT, so we
-- first add it with DEFAULT, then the DEFAULT is stored in the schema but
-- already all rows get 0.
addAccountIndexColumn :: Sqlite.Connection -> Text -> IO ()
addAccountIndexColumn conn tbl =
    exec conn
        $ "ALTER TABLE "
            <> tbl
            <> " ADD COLUMN account_index INTEGER NOT NULL DEFAULT 0 ;"

-- ---------------------------------------------------------------------------
-- seq_state
-- ---------------------------------------------------------------------------

rebuildSeqState :: Sqlite.Connection -> IO ()
rebuildSeqState conn = do
    exec conn
        "ALTER TABLE seq_state RENAME TO seq_state_v5 ;"
    exec conn
        "CREATE TABLE seq_state \
        \( wallet_id         TEXT    NOT NULL \
        \, account_index     INTEGER NOT NULL DEFAULT 0 \
        \, external_gap      INTEGER NOT NULL \
        \, internal_gap      INTEGER NOT NULL \
        \, account_xpub      BLOB    NOT NULL \
        \, policy_xpub       BLOB \
        \, reward_xpub       BLOB    NOT NULL \
        \, derivation_prefix TEXT    NOT NULL \
        \, change_addr_mode  TEXT    NOT NULL \
        \, PRIMARY KEY (wallet_id, account_index) \
        \, FOREIGN KEY (wallet_id) REFERENCES wallet (wallet_id) \
        \    ON DELETE CASCADE \
        \) ;"
    exec conn
        "INSERT INTO seq_state SELECT \
        \  wallet_id, account_index \
        \, external_gap, internal_gap \
        \, account_xpub, policy_xpub, reward_xpub \
        \, derivation_prefix, change_addr_mode \
        \FROM seq_state_v5 ;"
    exec conn "DROP TABLE seq_state_v5 ;"

-- ---------------------------------------------------------------------------
-- seq_state_pending
-- ---------------------------------------------------------------------------

rebuildSeqStatePending :: Sqlite.Connection -> IO ()
rebuildSeqStatePending conn = do
    exec conn
        "ALTER TABLE seq_state_pending \
        \    RENAME TO seq_state_pending_v5 ;"
    exec conn
        "CREATE TABLE seq_state_pending \
        \( wallet_id      TEXT    NOT NULL \
        \, account_index  INTEGER NOT NULL DEFAULT 0 \
        \, pending_ix     INTEGER NOT NULL \
        \, PRIMARY KEY (wallet_id, account_index, pending_ix) \
        \, FOREIGN KEY (wallet_id) REFERENCES wallet (wallet_id) \
        \    ON DELETE CASCADE \
        \) ;"
    exec conn
        "INSERT INTO seq_state_pending SELECT \
        \  wallet_id, account_index, pending_ix \
        \FROM seq_state_pending_v5 ;"
    exec conn "DROP TABLE seq_state_pending_v5 ;"

-- ---------------------------------------------------------------------------
-- tx_meta
-- ---------------------------------------------------------------------------

rebuildTxMeta :: Sqlite.Connection -> IO ()
rebuildTxMeta conn = do
    exec conn
        "ALTER TABLE tx_meta RENAME TO tx_meta_v5 ;"
    exec conn
        "CREATE TABLE tx_meta \
        \( tx_id            TEXT    NOT NULL \
        \, wallet_id        TEXT    NOT NULL \
        \, account_index    INTEGER NOT NULL DEFAULT 0 \
        \, status           TEXT    NOT NULL \
        \, direction        BOOLEAN NOT NULL \
        \, slot             INTEGER NOT NULL \
        \, block_height     INTEGER NOT NULL \
        \, amount           INTEGER NOT NULL \
        \, data             TEXT \
        \, slot_expires     INTEGER \
        \, fee              INTEGER \
        \, script_validity  BOOLEAN \
        \, PRIMARY KEY (tx_id, wallet_id, account_index) \
        \, FOREIGN KEY (wallet_id) REFERENCES wallet (wallet_id) \
        \    ON DELETE CASCADE \
        \) ;"
    exec conn
        "INSERT INTO tx_meta SELECT \
        \  tx_id, wallet_id, account_index, status, direction \
        \, slot, block_height, amount, data, slot_expires \
        \, fee, script_validity \
        \FROM tx_meta_v5 ;"
    exec conn "DROP TABLE tx_meta_v5 ;"
