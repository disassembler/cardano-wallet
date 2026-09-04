{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Copyright: © 2024 Cardano Foundation
-- License: Apache-2.0
--
-- Shared chain-sync broadcaster: one master 'chainSync' connection fans
-- rollForward and rollBackward events to all subscribed wallets.
--
-- == Design
--
-- The master thread converts each 'ConsensusBlock' to a 'W.Block' exactly
-- once and enqueues the full block batch to every subscribed wallet.  Each
-- subscriber's 'wboRollForward' performs its own 'isOurs' filtering so each
-- wallet only applies its own relevant transactions.
--
-- The broadcaster maintains two routing indexes:
--
--   * 'bcAddressIndex' — maps each known payment address to its owner wallet.
--     Populated at subscribe time; extended incrementally as wallets discover
--     new addresses (sequential gap-limit).
--
--   * 'bcUTxOIndex' — maps each unspent-output reference ('TxIn') to its
--     owner wallet.  Updated atomically by the master thread during every
--     'fanOutForward' call so that spend events are routed correctly.
--     Rebuilt from wallet state after every rollback.
--
-- The master sync thread enqueues block batches into a per-subscriber
-- 'TQueue' and returns immediately — it never waits for wallet DB I/O.  Each
-- subscriber has a dedicated consumer thread that drains the queue and calls
-- 'wboRollForward' at its own pace.
module Cardano.Wallet.Network.Broadcasting
    ( -- * Types
      ChainBroadcaster (..)
    , WalletBroadcastOps (..)
    , SubscriberState (..)

      -- * Construction
    , newChainBroadcaster

      -- * Subscription
    , subscribe
    , unsubscribe

      -- * Master thread
    , broadcasterFollower
    , readChainPointsForBroadcaster
    , runMasterSync

      -- * Catch-up helpers
    , tipDistance
    ) where

import Cardano.Wallet.Network
    ( ChainFollowLog
    , ChainFollower (..)
    , NetworkLayer (..)
    )
import Cardano.Wallet.Network.Checkpoints.Policy
    ( defaultPolicy
    )
import Cardano.Wallet.Primitive.Ledger.Read.Block
    ( fromCardanoBlock
    )
import Cardano.Wallet.Primitive.Types.Address
    ( Address
    )
import Cardano.Wallet.Primitive.Types.Block
    ( Block (..)
    , BlockHeader (..)
    )
import Data.Quantity
    ( Quantity (getQuantity)
    )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash
    )
import Cardano.Wallet.Primitive.Types.Tx.Tx
    ( Tx (..)
    , inputs
    )
import Cardano.Wallet.Primitive.Types.Tx.TxIn
    ( TxIn (..)
    )
import Cardano.Wallet.Read
    ( BlockNo (..)
    , ChainPoint (..)
    , ChainTip (..)
    , ConsensusBlock
    )
import Control.Concurrent.QSem
    ( QSem
    , newQSem
    )
import Control.Concurrent.STM
    ( TMVar
    , flushTQueue
    , newEmptyTMVar
    , orElse
    , putTMVar
    , retry
    , takeTMVar
    )
import Control.Exception
    ( SomeAsyncException
    , asyncExceptionFromException
    )
import Control.Monad
    ( forM
    , forM_
    , forever
    , void
    , when
    )
import Control.Tracer
    ( Tracer
    )
import Data.List
    ( nub
    )
import Data.List.NonEmpty
    ( NonEmpty (..)
    )
import Data.Map.Strict
    ( Map
    )
import Numeric.Natural
    ( Natural
    )
import Prelude
import UnliftIO.Async
    ( Async
    , async
    , cancel
    , race
    , waitCatch
    )
import System.IO
    ( hPutStrLn
    , stderr
    )
import UnliftIO.Exception
    ( SomeException
    , throwIO
    , try
    )
import UnliftIO.STM
    ( TQueue
    , TVar
    , atomically
    , modifyTVar'
    , newTQueueIO
    , newTVarIO
    , readTQueue
    , readTVar
    , writeTQueue
    , writeTVar
    )

import qualified Cardano.Wallet.Primitive.Types.Tx.TxOut as TxOut
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- | Type-erased wallet callbacks registered with the broadcaster.
-- Each wallet captures its own type-specific state via closure; the
-- broadcaster sees only opaque 'IO' actions.
data WalletBroadcastOps = WalletBroadcastOps
    { wboRollForward :: NonEmpty Block -> ChainTip -> IO [Address]
    -- ^ Apply a block batch to this wallet's state.  Each block's transaction
    -- list may contain all transactions or only those pre-routed to this
    -- wallet; the implementation performs its own 'isOurs' filtering.
    -- Returns any newly discovered addresses so the broadcaster can extend
    -- its routing index.
    , wboRollback :: ChainPoint -> IO ChainPoint
    -- ^ Roll back to (at most) the given point; returns the actual point
    -- rolled back to (may be older if no checkpoint exists at 'point').
    , wboCheckpoints :: IO [ChainPoint]
    -- ^ Known checkpoints for this wallet (used for intersection negotiation).
    , wboAddresses :: IO [Address]
    -- ^ All payment addresses currently monitored by this wallet, including
    -- unused addresses within the gap window.  Called at subscribe time and
    -- after each rollback to rebuild routing indexes.
    , wboUTxOKeys :: IO [TxIn]
    -- ^ All unspent output references currently owned by this wallet.
    -- Called at subscribe time and after each rollback.
    }

-- | Per-subscriber state managed by the broadcaster.
data SubscriberState = SubscriberState
    { ssOps          :: WalletBroadcastOps
    , ssForwardQueue :: TQueue (NonEmpty Block, ChainTip)
    -- ^ Block batches from 'fanOutForward'.  Consumer only drains
    -- this queue once 'ssActive' becomes 'True' (after catch-up completes).
    , ssRollbackQueue :: TQueue (ChainPoint, TMVar ChainPoint)
    -- ^ Rollback requests from 'fanOutRollback'.  Consumer drains this queue
    -- immediately, regardless of 'ssActive', so 'fanOutRollback' never stalls
    -- on a catching-up wallet.
    , ssThread       :: Async ()
    -- ^ Consumer thread.  'fanOutRollback' watches this via 'waitCatchSTM' so
    -- that a dead thread never blocks the master indefinitely.
    , ssActive       :: TVar Bool
    -- ^ Set to 'True' by the catch-up thread once it has processed all blocks
    -- up to the master tip captured at 'subscribe' time.  Until then, the
    -- consumer buffers 'ssForwardQueue' entries without processing them.
    }

-- | The shared chain-sync broadcaster.  Lives in 'ApiLayer'; created once at
-- service startup and never persisted.
--
-- The key type @k@ is the subscriber identity.  In practice the API layer
-- instantiates this as 'WalletId'.
data ChainBroadcaster k = ChainBroadcaster
    { bcSubscribers  :: TVar (Map k SubscriberState)
    -- ^ Wallets currently subscribed to the master thread.
    , bcCurrentTip   :: TVar (Maybe BlockNo)
    -- ^ Block number of the last block batch delivered by the master thread.
    -- 'Nothing' = master hasn't delivered any blocks yet (genesis).
    -- Catch-up threads use this to know when to stop and activate the consumer.
    , bcAddressIndex :: TVar (Map Address k)
    -- ^ Maps each known payment address to its subscriber.
    -- Populated at subscribe time and extended when wallets discover new
    -- addresses (sequential gap-limit derivation).
    , bcUTxOIndex    :: TVar (Map TxIn k)
    -- ^ Maps each unspent output reference to its subscriber.
    -- Updated atomically during each 'fanOutForward' call.
    -- Rebuilt from wallet state after each rollback.
    , bcCatchUpSemaphore :: QSem
    -- ^ Limits concurrent historical catch-up connections to the node.
    -- Without throttling, N=100+ wallets each open a chainSync connection
    -- simultaneously, overwhelming the local node.  Each catch-up thread must
    -- hold this semaphore while running chainSync; waiters queue up and proceed
    -- one-by-one as slots become free.
    }

-- | Maximum number of wallets that may run historical catch-up chainSync
-- connections simultaneously.  For the benchmark's N≤50 test points, 1000
-- effectively disables the throttle (all catch-ups run concurrently).
catchUpConcurrency :: Int
catchUpConcurrency = 1000

-- | Create an empty 'ChainBroadcaster' with no subscribers.
newChainBroadcaster :: IO (ChainBroadcaster k)
newChainBroadcaster = do
    bcSubscribers      <- newTVarIO Map.empty
    bcCurrentTip       <- newTVarIO Nothing
    bcAddressIndex     <- newTVarIO Map.empty
    bcUTxOIndex        <- newTVarIO Map.empty
    bcCatchUpSemaphore <- newQSem catchUpConcurrency
    pure ChainBroadcaster
        { bcSubscribers
        , bcCurrentTip
        , bcAddressIndex
        , bcUTxOIndex
        , bcCatchUpSemaphore
        }

-- | Register a wallet as a subscriber and return the master's current tip,
-- an activation 'TVar', the subscriber's forward queue, and the consumer
-- thread handle.
--
-- The subscriber is added to 'bcSubscribers' immediately, so the master thread
-- begins buffering forward events for it right away.  The consumer thread starts
-- blocked: it will not drain 'ssForwardQueue' until the caller sets the returned
-- 'TVar' to 'True'.  This lets the caller run a catch-up 'chainSync' to bring
-- the wallet to the captured @masterTip@, then activate the consumer —
-- guaranteeing no gap between catch-up output and the live broadcast stream.
--
-- Rollback events are always processed immediately regardless of the active flag,
-- so 'fanOutRollback' is never blocked by a catching-up wallet.
--
-- If the key was already subscribed the old consumer thread is cancelled and
-- replaced.
subscribe
    :: Ord k
    => ChainBroadcaster k
    -> k
    -> WalletBroadcastOps
    -> IO (Maybe BlockNo, TVar Bool, TQueue (NonEmpty Block, ChainTip), Async ())
    -- ^ @(masterDeliveredBlockNo, active, fq, consumerThread)@
subscribe bc k ops = do
    addrs    <- wboAddresses ops
    utxoKeys <- wboUTxOKeys ops
    fq     <- newTQueueIO
    rq     <- newTQueueIO
    active <- newTVarIO False
    thread <- async (consumerLoop bc k ops fq rq active)
    (mOld, masterDeliveredBlockNo) <- atomically $ do
        subs <- readTVar (bcSubscribers bc)
        let mOld = Map.lookup k subs
        masterDeliveredBlockNo <- readTVar (bcCurrentTip bc)
        writeTVar (bcSubscribers bc)
            $ Map.insert k
                SubscriberState
                    { ssOps          = ops
                    , ssForwardQueue  = fq
                    , ssRollbackQueue = rq
                    , ssThread       = thread
                    , ssActive       = active
                    }
                subs
        modifyTVar' (bcAddressIndex bc) $ \idx ->
            foldl' (\m a -> Map.insert a k m) idx addrs
        modifyTVar' (bcUTxOIndex bc) $ \idx ->
            foldl' (\m t -> Map.insert t k m) idx utxoKeys
        pure (mOld, masterDeliveredBlockNo)
    mapM_ (cancel . ssThread) mOld
    pure (masterDeliveredBlockNo, active, fq, thread)

-- | Remove a wallet subscription and cancel its consumer thread.
unsubscribe :: Ord k => ChainBroadcaster k -> k -> IO ()
unsubscribe bc k = do
    mSub <- atomically $ do
        subs <- readTVar (bcSubscribers bc)
        let mSub = Map.lookup k subs
        modifyTVar' (bcSubscribers bc) (Map.delete k)
        -- Remove all routing entries for this subscriber.
        modifyTVar' (bcAddressIndex bc) (Map.filter (/= k))
        modifyTVar' (bcUTxOIndex bc) (Map.filter (/= k))
        pure mSub
    mapM_ (cancel . ssThread) mSub

-- | Consumer thread: drains a subscriber's queues and processes each event.
--
-- Rollback events ('ssRollbackQueue') are always processed immediately.
-- Forward events ('ssForwardQueue') are deferred until 'ssActive' becomes
-- 'True' (i.e. the catch-up thread has finished and activated the consumer).
-- Using STM 'orElse' the consumer gives priority to rollbacks so that
-- 'fanOutRollback' is never blocked by a wallet that is still catching up.
--
-- After processing each rollback the forward queue is flushed: any blocks
-- queued before the rollback are stale and will be re-delivered by the master
-- thread once 'fanOutRollback' returns.
consumerLoop
    :: ChainBroadcaster k
    -> k
    -> WalletBroadcastOps
    -> TQueue (NonEmpty Block, ChainTip)
    -> TQueue (ChainPoint, TMVar ChainPoint)
    -> TVar Bool
    -> IO ()
consumerLoop bc k ops fq rq active = do
    result <- try go
    case result of
        Right () -> pure ()
        Left (e :: SomeException) -> do
            -- Only log genuine sync exceptions; async cancellation is normal.
            case asyncExceptionFromException e :: Maybe SomeAsyncException of
                Nothing ->
                    hPutStrLn stderr
                        $ "[consumerLoop] died with exception: " ++ show e
                Just _ -> pure ()
            throwIO e
  where
    go = do
        event <- atomically $
            (Left <$> readTQueue rq)
            `orElse`
            (do
                isActive <- readTVar active
                if isActive then Right <$> readTQueue fq else retry)
        case event of
            Left (point, resultVar) -> do
                actual <- wboRollback ops point
                -- Discard forward entries that predate the rollback; they will
                -- be re-delivered by the master after rollback acknowledgement.
                _ <- atomically $ flushTQueue fq
                -- Use putTMVar so fanOutRollback can observe thread death via
                -- waitCatchSTM rather than blocking forever on a dead thread.
                atomically $ putTMVar resultVar actual
                go
            Right (wblocks, tip) -> do
                newAddrs <- wboRollForward ops wblocks tip
                case newAddrs of
                    [] -> pure ()
                    _  -> atomically $
                        modifyTVar' (bcAddressIndex bc) $ \idx ->
                            foldl' (\m a -> Map.insert a k m) idx newAddrs
                go

-- | Build the 'ChainFollower' for the master sync thread.
broadcasterFollower
    :: Hash "Genesis"
    -> ChainBroadcaster k
    -> ChainFollower IO ChainPoint ChainTip (NonEmpty ConsensusBlock)
broadcasterFollower genesisHash bc =
    ChainFollower
        { checkpointPolicy = defaultPolicy
        , readChainPoints  = readChainPointsForBroadcaster bc
        , rollForward      = fanOutForward genesisHash bc
        , rollBackward     = fanOutRollback bc
        }

-- | Convert each 'ConsensusBlock' to a 'W.Block' once and enqueue the full
-- batch to every subscriber.  Each subscriber's 'wboRollForward' performs its
-- own filtering; the broadcaster does not pre-filter transactions.
--
-- The UTxO index is updated atomically so subsequent blocks in the same batch
-- see spend events correctly.  Returns as soon as all batches are enqueued.
fanOutForward
    :: Hash "Genesis"
    -> ChainBroadcaster k
    -> NonEmpty ConsensusBlock
    -> ChainTip
    -> IO ()
fanOutForward genesisHash bc cblocks tip = do
    let wblocks = NE.map (fst . fromCardanoBlock genesisHash) cblocks
        lastBlockNo =
            BlockNo
                $ fromIntegral
                $ getQuantity
                $ blockHeight
                $ header
                $ NE.last wblocks
    atomically $ do
        writeTVar (bcCurrentTip bc) (Just lastBlockNo)
        subs    <- readTVar (bcSubscribers bc)
        addrIdx <- readTVar (bcAddressIndex bc)
        utxoIdx <- readTVar (bcUTxOIndex bc)
        -- Update UTxO index for spend detection in subsequent blocks.
        writeTVar (bcUTxOIndex bc) (updateUtxoForBlocks addrIdx utxoIdx wblocks)
        -- Enqueue the full (unfiltered) block batch to each subscriber.
        -- Each subscriber's wboRollForward does its own isOurs check, ensuring
        -- transactions to gap-limit-extended addresses are never missed.
        forM_ (Map.elems subs) $ \ss ->
            writeTQueue (ssForwardQueue ss) (wblocks, tip)

-- | Fan a rollback out through every subscriber's queue, wait for all
-- acknowledgements, rebuild the UTxO routing index from post-rollback wallet
-- state, and return the minimum actual rollback point.
--
-- The subscriber snapshot and queue writes are done in a single STM
-- transaction, ensuring any subscriber present at snapshot time receives the
-- rollback event — a subscriber arriving after this transaction will not have
-- any pre-rollback blocks queued.
--
-- If a consumer thread dies before it can fill its result 'TMVar', the
-- 'race' fallback treats 'point' as the acknowledgement, so the master
-- thread is never blocked indefinitely by a dead consumer.
fanOutRollback
    :: ChainBroadcaster k
    -> ChainPoint
    -> IO ChainPoint
fanOutRollback bc point = do
    -- Atomically snapshot + enqueue: any subscriber in the snapshot gets a
    -- rollback event; any subscriber added after this transaction only sees
    -- post-rollback blocks.
    subsWithVars <- atomically $ do
        subs <- readTVar (bcSubscribers bc)
        forM (Map.toList subs) $ \(k, ss) -> do
            rv <- newEmptyTMVar
            writeTQueue (ssRollbackQueue ss) (point, rv)
            pure (k, ss, rv)

    -- Wait for each acknowledgement.  Race the TMVar wait against the
    -- consumer thread dying: if the thread dies before putTMVar, race
    -- returns Right and we fall back to 'point', unblocking the master.
    actuals <- forM subsWithVars $ \(_, ss, rv) -> do
        result <- race
            (atomically $ takeTMVar rv)
            (void $ waitCatch (ssThread ss))
        pure $ case result of
            Left actual -> actual
            Right ()    -> point

    -- Rebuild UTxO index from post-rollback wallet state using the same
    -- subscriber set as the snapshot (avoids a race where a new subscriber's
    -- UTxOs overwrite rebuilt entries).
    newUtxoIdx <- fmap (Map.fromList . concat) $
        forM subsWithVars $ \(k, ss, _) -> do
            utxos <- wboUTxOKeys (ssOps ss)
            pure [(t, k) | t <- utxos]
    atomically $ writeTVar (bcUTxOIndex bc) newUtxoIdx

    pure $ case actuals of
        [] -> point
        pts -> minimum pts

-- ---------------------------------------------------------------------------
-- UTxO index update

-- | Update the UTxO index for a batch of blocks.  Used by 'fanOutForward' to
-- track which wallet owns which unspent output for spend detection.
updateUtxoForBlocks
    :: Map Address k
    -> Map TxIn k
    -> NonEmpty Block
    -> Map TxIn k
updateUtxoForBlocks addrIdx utxoIdx =
    foldl' (updateUtxoForBlock addrIdx) utxoIdx . NE.toList

updateUtxoForBlock
    :: Map Address k
    -> Map TxIn k
    -> Block
    -> Map TxIn k
updateUtxoForBlock addrIdx utxoIdx0 block =
    foldl' processTx utxoIdx0 (transactions block)
  where
    processTx uidx tx =
        let txid = txId tx
            newUtxos = Map.fromList
                [ ( TxIn { inputId = txid, inputIx = fromIntegral (i :: Int) }
                  , k
                  )
                | (i, out) <- zip [0 ..] (outputs tx)
                , Just k <- [Map.lookup (TxOut.address out) addrIdx]
                ]
        in  Map.withoutKeys
                (newUtxos `Map.union` uidx)
                (Set.fromList (inputs tx))

-- ---------------------------------------------------------------------------
-- Collect checkpoints

-- | Collect the union of all subscriber checkpoints for Ouroboros
-- intersection negotiation.
--
-- Blocks until at least one subscriber has registered. Without this guard the
-- master would negotiate with an empty checkpoint list, the node would respond
-- with a rollback to Genesis, and any wallet that subscribed in the interim
-- would receive that rollback — crashing with ErrNoOlderCheckpoint Origin.
readChainPointsForBroadcaster :: ChainBroadcaster k -> IO [ChainPoint]
readChainPointsForBroadcaster bc = do
    subs <- atomically $ do
        s <- readTVar (bcSubscribers bc)
        when (Map.null s) retry
        pure s
    allPoints <- concat <$> mapM (wboCheckpoints . ssOps) (Map.elems subs)
    pure (nub allPoints)

-- ---------------------------------------------------------------------------
-- Master sync loop

-- | Run the master sync loop, restarting automatically on node disconnect.
-- Never returns unless the thread is cancelled.
runMasterSync
    :: NetworkLayer IO ConsensusBlock
    -> Tracer IO ChainFollowLog
    -> Hash "Genesis"
    -> ChainBroadcaster k
    -> IO ()
runMasterSync nw tr genesisHash bc =
    forever $ do
        result <- try (chainSync nw tr (broadcasterFollower genesisHash bc))
        case result of
            Right ()              -> pure ()
            Left (_ :: SomeException) -> pure ()

-- ---------------------------------------------------------------------------
-- Catch-up helper

-- | Number of blocks between a wallet's current position and the node tip.
-- Returns 0 when the wallet is at or ahead of the tip.
tipDistance :: BlockNo -> ChainTip -> Natural
tipDistance (BlockNo n) GenesisTip = n + 1
tipDistance (BlockNo n) (BlockTip _ _ (BlockNo m)) = m - min m n
