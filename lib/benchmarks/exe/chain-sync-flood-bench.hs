{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | End-to-end chain-sync flood benchmark.
--
-- Starts a real local cluster (cardano-node + wallet server), floods the
-- mempool with valid transactions for 30 seconds, and samples sync lag +
-- process memory every 2 seconds.  Run on *master* and on *this branch*:
--
-- @
--   cabal run cardano-wallet-benchmarks:exe:chain-sync-flood-bench
-- @
--
-- == What is measured
--
-- For each observer-wallet count N ∈ {1, 5, 10, 20}:
--
--   1. Create N empty \"observer\" wallets.
--   2. Wait for all wallets (5 funded senders + N observers) to reach Ready.
--   3. Flood the mempool for FLOOD_SECS seconds by sending small transactions
--      between the funded sender wallets in a round-robin (one tx per sender
--      per TX_INTERVAL_MS).
--   4. Every SAMPLE_INTERVAL_S seconds, record:
--        * node tip block-height   (GET /v2/network/information)
--        * each wallet's tip height (GET /v2/wallets/{id})
--        * max lag = max(nodeTip − walletTip) across all wallets
--        * process RSS in MB       (/proc/self/status VmRSS)
--   5. After the flood, measure seconds until all wallets are Ready again.
--
-- == Cherry-pick to master
--
-- This file contains no branch-specific imports.  Copy it plus the cabal
-- stanza to master and run the same binary there.
--
-- == Interpreting results
--
-- * master:  N persistent miniprotocol sessions to the node (one per wallet).
--            Each new wallet adds one more block-fetch per produced block.
-- * branch:  1 shared session; wallets receive blocks via concurrent fan-out.
--
-- Expected differences on a loaded node:
--   * branch peak lag should not grow with N (single connection handles all).
--   * master peak lag may grow with N if the node becomes a bottleneck.
--   * branch RSS may be slightly higher (fan-out TVar overhead) but the
--     difference should be small compared to the per-wallet connection savings.
--
module Main (main) where

import Cardano.Wallet.Api.Types
    ( ApiNetworkInformation (..)
    , ApiWallet
    , WalletStyle (..)
    )
import Cardano.Wallet.Launch.Cluster.FileOf
    ( DirOf (..)
    , absolutize
    )
import Cardano.Wallet.Primitive.NetworkId
    ( NetworkDiscriminant (..)
    )
import Cardano.Wallet.Primitive.SyncProgress
    ( SyncProgress (..)
    )
import Control.Concurrent
    ( threadDelay
    )
import Control.Monad
    ( forM
    , forM_
    , replicateM
    )
import Control.Monad.IO.Class
    ( liftIO
    )
import Control.Monad.Trans.Resource
    ( runResourceT
    )
import Data.Aeson
    ( Value
    )
import Data.Generics.Internal.VL.Lens
    ( (^.)
    )
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , modifyIORef'
    , newIORef
    , readIORef
    )
import Data.List
    ( isPrefixOf
    )
import Data.Text
    ( Text
    )
import Data.Maybe
    ( fromMaybe
    )
import Data.Proxy
    ( Proxy (..)
    )
import Data.Time.Clock
    ( addUTCTime
    , diffUTCTime
    , getCurrentTime
    )
import GHC.TypeNats
    ( natVal
    )
import System.Environment
    ( lookupEnv
    )
import System.IO
    ( BufferMode (..)
    , hFlush
    , hSetBuffering
    , stderr
    , stdout
    )
import System.Path
    ( absRel
    )
import Test.Integration.Framework.DSL
    ( Context
    , Headers (..)
    , Payload (..)
    , emptyWallet
    , fixturePassphrase
    , fixtureWallet
    , listAddresses
    , request
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
    ( async
    , cancel
    )
import UnliftIO.Exception
    ( catch
    , SomeException
    )
import Prelude

import qualified Cardano.Wallet.Api.Link as Link
import qualified Cardano.Wallet.Launch.Cluster as Cluster
import qualified Data.Aeson as Aeson
import qualified Network.HTTP.Types.Status as HTTP

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

floodSecs :: Int
floodSecs = 30

sampleIntervalSecs :: Int
sampleIntervalSecs = 2

txIntervalMs :: Int
txIntervalMs = 500  -- one tx per sender every 500 ms → ~10 tx/s with 5 senders

numSenders :: Int
numSenders = 5

observerCounts :: [Int]
observerCounts = [1, 5, 10, 20, 50]

sendLovelace :: Integer
sendLovelace = 1_000_000  -- 1 ADA per tx

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

main :: forall netId. (netId ~ 42) => IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    withTestsSetup $ \testDir (tr, tracers) -> do
        localClusterEra <- Cluster.clusterEraFromEnv
        let testnetMagic = Cluster.TestnetMagic (natVal (Proxy @netId))
        testDataDir <- do
            dir <- fromMaybe "." <$> lookupEnv "CARDANO_WALLET_TEST_DATA"
            DirOf <$> absolutize (absRel dir)
        let testingCtx = TestingCtx{..}

        -- Outer runResourceT keeps sender wallets alive across all N runs.
        withContext testingCtx $ \ctx ->
            runResourceT $ do
                liftIO $ do
                    putStrLn "\n=== chain-sync flood benchmark ==="
                    printf "  Flood: %d s  |  sample every %d s  |  tx interval %d ms\n"
                        floodSecs sampleIntervalSecs txIntervalMs
                    printf "  Senders: %d  |  observer counts: %s\n"
                        numSenders (show observerCounts)
                    putStrLn ""

                -- Create the funded sender wallets once, reused for every N.
                senders <- replicateM numSenders (fixtureWallet ctx)
                liftIO $ putStrLn $ "Created " <> show numSenders <> " funded sender wallets.\n"

                -- Pre-fetch one receive address per sender for the round-robin.
                -- We get them as JSON values so we can embed them in payloads without
                -- needing to carry around the typed ApiAddress n.
                senderAddrJsons <- liftIO $ forM senders $ \w -> do
                    addrs <- listAddresses @('Testnet 42) ctx w
                    case addrs of
                        addr : _ -> case Aeson.toJSON (addr ^. #id) of
                            Aeson.String t -> return t
                            other -> error $ "unexpected address JSON: " <> show other
                        [] -> error "sender wallet has no addresses"

                -- Run one data-point per observer count.
                -- Each inner runResourceT creates and cleans up that N's observers.
                results <- liftIO $ forM observerCounts $ \n -> do
                    putStrLn $ "--- N=" <> show n <> " observer wallets ---"
                    r <- runResourceT $ do
                        observers <- replicateM n (emptyWallet ctx)
                        liftIO $ runOnce ctx senders senderAddrJsons observers
                    putStrLn ""
                    return (n, r)

                liftIO $ printSummary results

-- ---------------------------------------------------------------------------
-- Single data-point: N observer wallets
-- ---------------------------------------------------------------------------

data Sample = Sample
    { sampleElapsed  :: Int       -- seconds since flood start
    , nodeTipHeight  :: Integer
    , walletLagMax   :: Integer   -- max(nodeTip − walletTip)
    , anyNotReady    :: Bool
    , rssMB          :: Double
    }

data RunResult = RunResult
    { samples      :: [Sample]
    , txsSubmitted :: Int
    , catchUpSecs  :: Double
    }

runOnce
    :: Context
    -> [ApiWallet]         -- funded sender wallets
    -> [Text]              -- destination address texts (parallel to senders)
    -> [ApiWallet]         -- observer wallets (managed by caller's ResourceT)
    -> IO RunResult
runOnce ctx senders senderAddrJsons observers = do
    let allWallets = senders <> observers

    putStr $ "  Waiting for " <> show (length allWallets) <> " wallets to be Ready (max 3 min)... "
    hFlush stdout
    allReady <- waitAllReadyTimeout ctx allWallets 600
    putStrLn $ if allReady then "done." else "TIMEOUT — proceeding anyway."

    -- Start transaction flood in a background thread.
    txCounter <- newIORef (0 :: Int)
    floodTask <- async $ floodLoop ctx senders senderAddrJsons txCounter

    -- Sample loop.
    samplesRef <- newIORef ([] :: [Sample])
    let totalSamples = floodSecs `div` sampleIntervalSecs
    forM_ [1 .. totalSamples] $ \i -> do
        threadDelay (sampleIntervalSecs * 1_000_000)
        s <- takeSample ctx allWallets (i * sampleIntervalSecs)
        modifyIORef' samplesRef (s :)
        printf "  t=%ds  node=%d  lag=%d  anyBehind=%s  rss=%dMB\n"
            (sampleElapsed s)
            (nodeTipHeight s)
            (walletLagMax s)
            (if anyNotReady s then "YES" else "no" :: String)
            (round (rssMB s) :: Int)

    cancel floodTask
    txCount <- readIORef txCounter

    -- Measure time to re-sync after flood (max 3 min).
    tFloodEnd <- getCurrentTime
    _ <- waitAllReadyTimeout ctx allWallets 600
    tCaughtUp <- getCurrentTime
    let catchUp = realToFrac (diffUTCTime tCaughtUp tFloodEnd) :: Double

    printf "  → %d txs submitted.  Post-flood catch-up: %.1fs\n" txCount catchUp

    ss <- reverse <$> readIORef samplesRef
    return RunResult{samples = ss, txsSubmitted = txCount, catchUpSecs = catchUp}

-- ---------------------------------------------------------------------------
-- Transaction flood
-- ---------------------------------------------------------------------------

floodLoop
    :: Context
    -> [ApiWallet]
    -> [Text]      -- destination address strings (parallel to senders)
    -> IORef Int
    -> IO ()
floodLoop ctx senders destAddrs txCounter =
    go (cycle $ zip senders (drop 1 $ cycle destAddrs))
  where
    go [] = return ()  -- unreachable: cycle is infinite
    go ((src, destAddr) : rest) = do
        threadDelay (txIntervalMs * 1_000)
        let payload =
                Json
                    $ Aeson.object
                        [ "payments"
                            Aeson..= Aeson.toJSON
                                [ Aeson.object
                                    [ "address" Aeson..= destAddr
                                    , "amount"
                                        Aeson..= Aeson.object
                                            [ "quantity" Aeson..= sendLovelace
                                            , "unit" Aeson..= ("lovelace" :: String)
                                            ]
                                    ]
                                ]
                        , "passphrase" Aeson..= fixturePassphrase
                        ]
        r <-
            request @Value
                ctx
                (Link.createTransactionOld @'Shelley src)
                Default
                payload
        case fst r of
            s | s == HTTP.status202 ->
                atomicModifyIORef' txCounter (\c -> (c + 1, ()))
            _ -> return ()  -- ignore failures (wallet may be temporarily out of UTxO)
        go rest

-- ---------------------------------------------------------------------------
-- Metric sampling
-- ---------------------------------------------------------------------------

takeSample :: Context -> [ApiWallet] -> Int -> IO Sample
takeSample ctx wallets elapsed = do
    -- Node tip
    netR <- request @ApiNetworkInformation ctx Link.getNetworkInfo Default Empty
    let nodeH =
            fromIntegral
                $ either (const 0) (^. #nodeTip . #block . #height . #getQuantity)
                $ snd netR
    -- Wallet tips
    walletStates <- forM wallets $ \w -> do
        r <- request @ApiWallet ctx (Link.getWallet @'Shelley w) Default Empty
        return $ case snd r of
            Right wt ->
                ( fromIntegral $ wt ^. #tip . #block . #height . #getQuantity
                , wt ^. #state . #getApiT
                )
            Left _ -> (0, Syncing minBound)
    let tips    = map fst walletStates
        states  = map snd walletStates
        maxLag  = maximum $ 0 : map (\h -> max 0 (nodeH - h)) tips
        notRdy  = any (\case Ready -> False; _ -> True) states
    mem <- getResidentMB
    return Sample
        { sampleElapsed = elapsed
        , nodeTipHeight = nodeH
        , walletLagMax  = maxLag
        , anyNotReady   = notRdy
        , rssMB         = mem
        }

-- | Wait up to @timeoutSecs@ for all wallets to reach Ready.
-- Returns True if all reached Ready, False if timed out.
waitAllReadyTimeout :: Context -> [ApiWallet] -> Int -> IO Bool
waitAllReadyTimeout ctx wallets timeoutSecs = do
    deadline <- addUTCTime (fromIntegral timeoutSecs) <$> getCurrentTime
    fmap and $ forM wallets (go deadline)
  where
    go deadline w = do
        r <- request @ApiWallet ctx (Link.getWallet @'Shelley w) Default Empty
        case fmap (^. #state . #getApiT) (snd r) of
            Right Ready -> return True
            _ -> do
                now <- getCurrentTime
                if now >= deadline
                    then return False
                    else threadDelay 500_000 >> go deadline w

-- ---------------------------------------------------------------------------
-- Process memory
-- ---------------------------------------------------------------------------

getResidentMB :: IO Double
getResidentMB =
    catch
        ( do
            content <- readFile "/proc/self/status"
            case filter ("VmRSS:" `isPrefixOf`) (lines content) of
                (l : _) -> case words l of
                    [_, kb, "kB"] -> return $ read kb / 1024.0
                    _             -> return 0
                _ -> return 0
        )
        (\(_ :: SomeException) -> return 0)

-- ---------------------------------------------------------------------------
-- Summary table
-- ---------------------------------------------------------------------------

printSummary :: [(Int, RunResult)] -> IO ()
printSummary results = do
    putStrLn "=== Summary (compare master vs branch) ==="
    putStrLn "  N  | peak lag (blocks) | peak RSS (MB) | txs submitted | catch-up (s)"
    putStrLn "  ---|-------------------|---------------|---------------|-------------"
    forM_ results $ \(n, RunResult{..}) -> do
        let peakLag = maximum $ 0 : map walletLagMax samples
            peakMem = maximum $ 0.0 : map rssMB samples
        printf "  %2d | %17d | %11dMB | %13d | %.1fs\n"
            n
            peakLag
            (round peakMem :: Int)
            txsSubmitted
            catchUpSecs
    putStrLn ""
    putStrLn "  Interpretation:"
    putStrLn "    master  → N node connections; peak lag & RSS grow with N"
    putStrLn "    branch  → 1 node connection; peak lag & RSS should be stable"
