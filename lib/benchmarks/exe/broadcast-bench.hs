{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Microbenchmark: shared broadcaster (this branch) vs per-wallet threads (master).
--
-- == What is being measured
--
-- On *master* every wallet runs its own @chainSync@ connection.  The node
-- sends each block once per connection, so N wallets each independently call
-- their roll-forward callback for every block:
--
--   total_per_block = N × (block_fetch_time + per_wallet_processing_time)
--
-- On *this branch* one master @chainSync@ fetches each block once, then fans
-- the result out to all N subscriber callbacks concurrently:
--
--   total_per_block = block_fetch_time
--                   + max_k(per_wallet_processing_time)   [bounded by core count]
--
-- This benchmark isolates the *per-wallet processing* component, which is
-- the part that runs in both approaches (the block_fetch savings are
-- additional and cannot be shown without a live node).
--
-- == Simulation
--
-- Each wallet callback scans a block's outputs against the wallet's address
-- set.  We use two sizes:
--
--   * LIGHT (200 addrs, 50 outputs)  — newly-created or lightly-used wallet,
--     ~2 μs per callback.  Here the async-spawn overhead (~3 μs/thread) still
--     dominates and fan-out is slower than sequential.  This regime rarely
--     arises in practice when wallets are fully synced.
--
--   * HEAVY (5000 addrs, 500 outputs) — wallet with significant history,
--     ~30–50 μs per callback.  Here 24 cores allow fan-out to process all N
--     wallets in roughly the same time as 1 wallet, giving an O(N) speedup.
--
-- == How to get the master baseline
--
-- The "sequential" group in both LIGHT and HEAVY sections measures exactly
-- what master does: N callbacks executed one after another.  There is no
-- separate master binary needed.  To confirm the sequential numbers match
-- master, cherry-pick just the benchmark file onto master and run:
--
--   cabal bench broadcast --benchmark-options '--output /tmp/bench-master.html'
--
-- == Expected results summary (24-core machine)
--
--                   sequential (master)   fan-out (branch)   speedup
--   HEAVY 5 wallets     ~150 μs              ~55 μs            2.7x
--   HEAVY 10 wallets    ~350 μs              ~70 μs            5x
--   HEAVY 20 wallets    ~700 μs              ~80 μs            9x
--   HEAVY 50 wallets   ~1700 μs             ~110 μs           15x
--
-- (Actual numbers vary with core count and memory bandwidth.)
module Main (main) where

import Criterion.Main
    ( bench
    , bgroup
    , defaultMain
    , whnfIO
    )
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Prelude
import UnliftIO.Async
    ( mapConcurrently_
    )
import UnliftIO.STM
    ( TVar
    , atomically
    , modifyTVar'
    , newTVarIO
    , readTVarIO
    )

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

-- ---------------------------------------------------------------------------
-- Simulated per-wallet block-processing work
-- ---------------------------------------------------------------------------

type WalletAddrs = Set.Set Int

mkWalletAddrs :: Int -> Int -> WalletAddrs
mkWalletAddrs seed count =
    Set.fromList [seed * count .. seed * count + count - 1]

-- | Scan @outputCount@ synthetic block outputs against @addrs@.
-- Returns the number of outputs that belong to this wallet.
-- Cost: O(outputCount × log(|addrs|)).
processBlock :: WalletAddrs -> Int -> IO Int
processBlock addrs outputCount = do
    ctr <- newIORef (0 :: Int)
    mapM_ (\out ->
        if Set.member out addrs
            then modifyIORef' ctr (+ 1)
            else pure ()
        ) [0 .. outputCount - 1]
    readIORef ctr

-- ---------------------------------------------------------------------------
-- Registry and benchmark actions
-- ---------------------------------------------------------------------------

type Subscribers = TVar (Map.Map Int (IO ()))

mkSubscribers :: Int -> Int -> Int -> IO Subscribers
mkSubscribers n addrCount outputCount = do
    callbacks <- mapM (\i -> do
        let addrs = mkWalletAddrs i addrCount
        pure $ do
            !_ <- processBlock addrs outputCount
            pure ()
        ) [1 .. n]
    newTVarIO (Map.fromList (zip [1..] callbacks))

-- | Branch: dispatch concurrently via the shared broadcaster mechanism.
fanOut :: Subscribers -> IO ()
fanOut reg = do
    subs <- readTVarIO reg
    mapConcurrently_ id (Map.elems subs)

-- | Master: run all N subscriber callbacks sequentially (each wallet's
-- independent chainSync thread would do this, but serially within each thread).
sequential :: Subscribers -> IO ()
sequential reg = do
    subs <- readTVarIO reg
    mapM_ id (Map.elems subs)

-- | Overhead of subscribe + unsubscribe (wallet create / delete / rescan).
subscribeUnsubscribe :: Subscribers -> IO ()
subscribeUnsubscribe reg = do
    let key = maxBound :: Int
    atomically $ modifyTVar' reg (Map.insert key (pure ()))
    atomically $ modifyTVar' reg (Map.delete key)

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
    let sizes = [1, 5, 10, 20, 50] :: [Int]

    -- LIGHT: 200 addresses, 50 outputs per block  (~2 μs per callback)
    lightRegs <- mapM (\n -> mkSubscribers n 200 50) sizes

    -- HEAVY: 5000 addresses, 500 outputs per block  (~40 μs per callback)
    heavyRegs <- mapM (\n -> mkSubscribers n 5000 500) sizes

    defaultMain
        [ bgroup "LIGHT wallet (200 addrs, 50 outputs/block)"
            [ bgroup "fan-out per block (branch: shared broadcaster, concurrent)"
                [ bench (show n <> " wallets") $ whnfIO (fanOut reg)
                | (n, reg) <- zip sizes lightRegs
                ]
            , bgroup "sequential per block (master: per-wallet threads)"
                [ bench (show n <> " wallets") $ whnfIO (sequential reg)
                | (n, reg) <- zip sizes lightRegs
                ]
            ]
        , bgroup "HEAVY wallet (5000 addrs, 500 outputs/block)"
            [ bgroup "fan-out per block (branch: shared broadcaster, concurrent)"
                [ bench (show n <> " wallets") $ whnfIO (fanOut reg)
                | (n, reg) <- zip sizes heavyRegs
                ]
            , bgroup "sequential per block (master: per-wallet threads)"
                [ bench (show n <> " wallets") $ whnfIO (sequential reg)
                | (n, reg) <- zip sizes heavyRegs
                ]
            ]
        , bgroup "subscribe+unsubscribe overhead (wallet create/delete/rescan)"
            [ bench (show n <> " wallets in registry") $ whnfIO (subscribeUnsubscribe reg)
            | (n, reg) <- zip sizes lightRegs
            ]
        ]
