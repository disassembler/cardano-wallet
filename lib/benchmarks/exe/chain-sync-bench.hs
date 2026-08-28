{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | End-to-end chain-sync scaling benchmark.
--
-- Starts a real local cluster (cardano-node + wallet server) and measures
-- how long it takes for N concurrently-created wallets to all reach the
-- @Ready@ sync state.
--
-- Run on *master* and on this branch to compare:
--
-- @
--   # on master
--   cabal run cardano-wallet-benchmarks:exe:chain-sync-bench
--
--   # on this branch
--   cabal run cardano-wallet-benchmarks:exe:chain-sync-bench
-- @
--
-- == What is measured
--
-- For each N:
--   * Create N wallets concurrently via the REST API.
--   * Poll every 500 ms until all N wallets report @state: Ready@.
--   * Record total elapsed wall time.
--
-- == What the numbers mean
--
-- During the *catch-up* phase (syncing from genesis to the current tip),
-- master and this branch behave identically — each wallet opens its own
-- miniprotocol connection to the node.  The primary difference between
-- branches appears in ongoing resource usage *after* the wallets are synced:
--
--   * master:  N persistent connections to the node (one per wallet)
--   * branch:  1 persistent connection shared by all N wallets
--
-- Timing differences in this benchmark are therefore expected to be small
-- for a freshly-started local cluster with a short chain.  The benchmark
-- is still useful to:
--
--   1. Verify correctness (all wallets eventually reach Ready on the branch).
--   2. Detect regressions if the branch inadvertently serialises sync work.
--   3. Provide a baseline for running against a longer chain (mainnet/preprod).
--
module Main (main) where

import Cardano.Wallet.Api.Types
    ( ApiWallet
    , WalletStyle (..)
    )
import Cardano.Wallet.Launch.Cluster.FileOf
    ( DirOf (..)
    , absolutize
    )
import Cardano.Wallet.Primitive.SyncProgress
    ( SyncProgress (..)
    )
import Control.Monad
    ( forM_
    , replicateM
    )
import Control.Monad.IO.Class
    ( liftIO
    )
import Control.Monad.Trans.Resource
    ( runResourceT
    )
import Data.Maybe
    ( fromMaybe
    )
import Data.Time.Clock
    ( NominalDiffTime
    , diffUTCTime
    , getCurrentTime
    )
import Data.Typeable
    ( Proxy (..)
    )
import GHC.TypeNats
    ( natVal
    )
import System.Environment
    ( lookupEnv
    )
import System.Path
    ( absRel
    )
import Test.Integration.Framework.DSL
    ( Context
    , Headers (..)
    , Payload (..)
    , emptyWallet
    , eventually
    , expectField
    , expectResponseCode
    , request
    , verify
    )
import Test.Integration.Framework.Setup
    ( TestingCtx (..)
    , withContext
    , withTestsSetup
    )
import Text.Printf
    ( printf
    )
import UnliftIO.Async
    ( forConcurrently_
    )
import Prelude

import qualified Cardano.Wallet.Api.Link as Link
import qualified Cardano.Wallet.Launch.Cluster as Cluster
import qualified Network.HTTP.Types.Status as HTTP

main :: forall netId. (netId ~ 42) => IO ()
main = withTestsSetup $ \testDir (tr, tracers) -> do
    localClusterEra <- Cluster.clusterEraFromEnv
    let testnetMagic = Cluster.TestnetMagic (natVal (Proxy @netId))
    testDataDir <- do
        dir <- fromMaybe "." <$> lookupEnv "CARDANO_WALLET_TEST_DATA"
        DirOf <$> absolutize (absRel dir)
    let testingCtx = TestingCtx{..}

    withContext testingCtx $ \ctx -> do
        putStrLn ""
        putStrLn "=== chain-sync scaling benchmark ==="
        putStrLn "N wallets | time-to-Ready (s)"
        putStrLn "----------+-------------------"
        forM_ [1, 5, 10, 20] $ \n -> do
            t <- benchmarkSyncN ctx n
            printf "%9d | %.3f\n" (n :: Int) (realToFrac t :: Double)
        putStrLn ""
        putStrLn "Notes:"
        putStrLn "  * On master each wallet holds a persistent node connection."
        putStrLn "  * On this branch wallets share one connection at the tip."
        putStrLn "  * Sync-time differences are small for a short local chain;"
        putStrLn "    connection-count savings are the primary benefit."

-- | Create @n@ wallets concurrently and return the wall time until all are
-- in the @Ready@ state.
benchmarkSyncN :: Context -> Int -> IO NominalDiffTime
benchmarkSyncN ctx n = do
    t0 <- getCurrentTime
    runResourceT $ do
        wallets <- replicateM n (emptyWallet ctx)
        liftIO $ forConcurrently_ wallets $ \w ->
            eventually "wallet is Ready" $ do
                r <-
                    request @ApiWallet
                        ctx
                        (Link.getWallet @'Shelley w)
                        Default
                        Empty
                verify r
                    [ expectResponseCode HTTP.status200
                    , expectField
                        (#state . #getApiT)
                        (`shouldBe` Ready)
                    ]
    t1 <- getCurrentTime
    return $ diffUTCTime t1 t0

-- inline shouldBe to avoid hspec-expectations import
shouldBe :: (Eq a, Show a) => a -> a -> IO ()
shouldBe x y
    | x == y    = return ()
    | otherwise = error $ "expected " <> show y <> " but got " <> show x
