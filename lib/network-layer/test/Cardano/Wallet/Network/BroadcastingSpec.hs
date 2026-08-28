{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Wallet.Network.BroadcastingSpec (spec) where

import Cardano.Wallet.Network.Broadcasting
    ( ChainBroadcaster (..)
    , SubscriberState (..)
    , WalletBroadcastOps (..)
    , newChainBroadcaster
    , readChainPointsForBroadcaster
    , subscribe
    , tipDistance
    , unsubscribe
    )
import Control.Monad
    ( void
    )
import Cardano.Wallet.Read
    ( BlockNo (..)
    , ChainPoint (..)
    , ChainTip (..)
    , SlotNo (..)
    , mockRawHeaderHash
    )
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Numeric.Natural
    ( Natural
    )
import Prelude
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldMatchList
    )
import UnliftIO.STM
    ( readTVarIO
    )

import qualified Data.Map.Strict as Map

spec :: Spec
spec = do
    describe "tipDistance" tipDistanceSpec
    describe "newChainBroadcaster" newChainBroadcasterSpec
    describe "subscribe/unsubscribe" subscribeSpec
    describe "WalletBroadcastOps callbacks" callbackSpec
    describe "readChainPointsForBroadcaster" chainPointsSpec

-- ---------------------------------------------------------------------------
-- tipDistance

tipDistanceSpec :: Spec
tipDistanceSpec = do
    it "genesis to genesis tip: blockNo + 1" $ do
        tipDistance (BlockNo 0) GenesisTip `shouldBe` 1
        tipDistance (BlockNo 5) GenesisTip `shouldBe` 6

    it "at tip: distance is 0" $ do
        tipDistance (BlockNo 10) (mockBlockTip 10) `shouldBe` 0

    it "behind tip: distance is tip - wallet" $ do
        tipDistance (BlockNo 5) (mockBlockTip 10) `shouldBe` 5

    it "wallet blockNo > reported tip: absolute difference" $ do
        tipDistance (BlockNo 10) (mockBlockTip 5) `shouldBe` 5

    it "one block behind tip gives distance 1" $ do
        tipDistance (BlockNo 9) (mockBlockTip 10) `shouldBe` 1

-- ---------------------------------------------------------------------------
-- newChainBroadcaster

newChainBroadcasterSpec :: Spec
newChainBroadcasterSpec = do
    it "starts with empty subscriber map" $ do
        bc <- newChainBroadcaster
        subs <- readTVarIO (bcSubscribers bc)
        Map.null subs `shouldBe` True

    it "starts with no delivered block" $ do
        bc <- newChainBroadcaster
        tip <- readTVarIO (bcCurrentTip bc)
        tip `shouldBe` (Nothing :: Maybe BlockNo)

-- ---------------------------------------------------------------------------
-- subscribe / unsubscribe

subscribeSpec :: Spec
subscribeSpec = do
    it "subscribe adds the key to subscribers" $ do
        bc <- newChainBroadcaster
        void $ subscribe bc (1 :: Int) noopOps
        subs <- readTVarIO (bcSubscribers bc)
        Map.member 1 subs `shouldBe` True

    it "unsubscribe removes the key" $ do
        bc <- newChainBroadcaster
        void $ subscribe bc (1 :: Int) noopOps
        unsubscribe bc 1
        subs <- readTVarIO (bcSubscribers bc)
        Map.member 1 subs `shouldBe` False

    it "unsubscribing a non-existent key is safe" $ do
        bc <- newChainBroadcaster
        unsubscribe bc (99 :: Int)
        subs <- readTVarIO (bcSubscribers bc)
        Map.null subs `shouldBe` True

    it "multiple distinct subscribers coexist" $ do
        bc <- newChainBroadcaster
        void $ subscribe bc (1 :: Int) noopOps
        void $ subscribe bc 2 noopOps
        void $ subscribe bc 3 noopOps
        subs <- readTVarIO (bcSubscribers bc)
        Map.size subs `shouldBe` 3

    it "subscribing the same key twice replaces the old ops" $ do
        bc <- newChainBroadcaster
        ref <- newIORef (0 :: Int)
        let ops1 = noopOps { wboCheckpoints = modifyIORef' ref (+ 1) >> pure [] }
            ops2 = noopOps { wboCheckpoints = modifyIORef' ref (+ 10) >> pure [] }
        void $ subscribe bc (1 :: Int) ops1
        void $ subscribe bc 1 ops2
        subs <- readTVarIO (bcSubscribers bc)
        _ <- wboCheckpoints (ssOps (subs Map.! 1))
        n <- readIORef ref
        n `shouldBe` 10

-- ---------------------------------------------------------------------------
-- WalletBroadcastOps callbacks

callbackSpec :: Spec
callbackSpec = do
    it "wboRollback is called with the requested point" $ do
        bc <- newChainBroadcaster
        ref <- newIORef GenesisPoint
        let pt = BlockPoint (SlotNo 7) (mockRawHeaderHash 7)
            ops = noopOps
                { wboRollback = \p -> do
                    modifyIORef' ref (const p)
                    pure p
                }
        void $ subscribe bc (1 :: Int) ops
        subs <- readTVarIO (bcSubscribers bc)
        _ <- wboRollback (ssOps (subs Map.! 1)) pt
        got <- readIORef ref
        got `shouldBe` pt

    it "wboCheckpoints returns what the wallet provides" $ do
        bc <- newChainBroadcaster
        let pts = [BlockPoint (SlotNo 1) (mockRawHeaderHash 1)]
            ops = noopOps { wboCheckpoints = pure pts }
        void $ subscribe bc (1 :: Int) ops
        subs <- readTVarIO (bcSubscribers bc)
        got <- wboCheckpoints (ssOps (subs Map.! 1))
        got `shouldBe` pts

-- ---------------------------------------------------------------------------
-- readChainPointsForBroadcaster

chainPointsSpec :: Spec
chainPointsSpec = do
    it "returns [] when no subscribers" $ do
        bc <- newChainBroadcaster
        pts <- readChainPointsForBroadcaster (bc :: ChainBroadcaster Int)
        pts `shouldBe` []

    it "collects checkpoints from all subscribers" $ do
        bc <- newChainBroadcaster
        let pt1 = BlockPoint (SlotNo 5) (mockRawHeaderHash 5)
            pt2 = BlockPoint (SlotNo 10) (mockRawHeaderHash 10)
            ops1 = noopOps { wboCheckpoints = pure [pt1] }
            ops2 = noopOps { wboCheckpoints = pure [pt2] }
        void $ subscribe bc (1 :: Int) ops1
        void $ subscribe bc 2 ops2
        pts <- readChainPointsForBroadcaster bc
        pts `shouldMatchList` [pt1, pt2]

    it "deduplicates checkpoints shared by multiple subscribers" $ do
        bc <- newChainBroadcaster
        let pt = BlockPoint (SlotNo 5) (mockRawHeaderHash 5)
            ops1 = noopOps { wboCheckpoints = pure [pt] }
            ops2 = noopOps { wboCheckpoints = pure [pt] }
        void $ subscribe bc (1 :: Int) ops1
        void $ subscribe bc 2 ops2
        pts <- readChainPointsForBroadcaster bc
        length pts `shouldBe` 1

    it "includes GenesisPoint when a subscriber reports it" $ do
        bc <- newChainBroadcaster
        let ops = noopOps { wboCheckpoints = pure [GenesisPoint] }
        void $ subscribe bc (1 :: Int) ops
        pts <- readChainPointsForBroadcaster bc
        pts `shouldMatchList` [GenesisPoint]

-- ---------------------------------------------------------------------------
-- Helpers

mockBlockTip :: Natural -> ChainTip
mockBlockTip n =
    ( BlockTip
        { slotNo = SlotNo (fromIntegral n)
        , headerHash = mockRawHeaderHash (fromIntegral n)
        , blockNo = BlockNo n
        }
        :: ChainTip
    )

noopOps :: WalletBroadcastOps
noopOps =
    WalletBroadcastOps
        { wboRollForward = \_ _ -> pure []
        , wboRollback = \pt -> pure pt
        , wboCheckpoints = pure []
        , wboAddresses = pure []
        , wboUTxOKeys = pure []
        }
