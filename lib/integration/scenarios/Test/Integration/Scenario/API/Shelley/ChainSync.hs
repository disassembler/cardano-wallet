{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE TypeApplications #-}

-- | Integration tests for the shared chain-sync broadcaster and the
-- per-wallet rescan endpoint.
module Test.Integration.Scenario.API.Shelley.ChainSync
    ( spec
    ) where

import Cardano.Wallet.Api.Types
    ( ApiWallet
    , WalletStyle (..)
    )
import Cardano.Wallet.Api.Types.Error
    ( ApiErrorInfo (..)
    , ApiErrorNoSuchWallet (ApiErrorNoSuchWallet)
    )
import Cardano.Wallet.Primitive.SyncProgress
    ( SyncProgress (..)
    )
import Control.Monad.Trans.Resource
    ( runResourceT
    )
import Data.Generics.Internal.VL.Lens
    ( (^.)
    )
import Prelude
import Test.Hspec
    ( SpecWith
    , describe
    , it
    )
import Test.Hspec.Expectations.Lifted
    ( shouldBe
    )
import Test.Integration.Framework.DSL
    ( Context
    , Payload (..)
    , Headers (..)
    , decodeErrorInfo
    , emptyWallet
    , eventually
    , expectField
    , expectResponseCode
    , request
    , verify
    )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Network.HTTP.Types.Status as HTTP

spec :: SpecWith Context
spec = describe "CHAIN_SYNC" $ do
    it "CHAIN_SYNC_01 - Newly created wallet eventually reaches Ready state"
        $ \ctx -> runResourceT @IO $ do
            w <- emptyWallet ctx
            eventually "wallet sync progress is Ready" $ do
                r <-
                    request @ApiWallet
                        ctx
                        (Link.getWallet @'Shelley w)
                        Default
                        Empty
                verify r
                    [ expectField
                        (#state . #getApiT)
                        (`shouldBe` Ready)
                    ]

    it "CHAIN_SYNC_02 - Rescan returns HTTP 202 for existing wallet"
        $ \ctx -> runResourceT @IO $ do
            w <- emptyWallet ctx
            r <-
                request @ApiWallet
                    ctx
                    (Link.postWalletRescan w)
                    Default
                    Empty
            expectResponseCode HTTP.status202 r

    it "CHAIN_SYNC_03 - Rescan for deleted wallet returns 404"
        $ \ctx -> runResourceT @IO $ do
            w <- emptyWallet ctx
            _ <-
                request @ApiWallet
                    ctx
                    (Link.deleteWallet @'Shelley w)
                    Default
                    Empty
            r <-
                request @ApiWallet
                    ctx
                    (Link.postWalletRescan w)
                    Default
                    Empty
            expectResponseCode HTTP.status404 r
            decodeErrorInfo r
                `shouldBe` NoSuchWallet
                    (ApiErrorNoSuchWallet (w ^. #id))

    it "CHAIN_SYNC_04 - Wallet re-syncs to Ready after rescan"
        $ \ctx -> runResourceT @IO $ do
            w <- emptyWallet ctx
            eventually "wallet is Ready before rescan" $ do
                r <-
                    request @ApiWallet
                        ctx
                        (Link.getWallet @'Shelley w)
                        Default
                        Empty
                verify r
                    [ expectField
                        (#state . #getApiT)
                        (`shouldBe` Ready)
                    ]
            _ <-
                request @ApiWallet
                    ctx
                    (Link.postWalletRescan w)
                    Default
                    Empty
            eventually "wallet is Ready after rescan" $ do
                r <-
                    request @ApiWallet
                        ctx
                        (Link.getWallet @'Shelley w)
                        Default
                        Empty
                verify r
                    [ expectField
                        (#state . #getApiT)
                        (`shouldBe` Ready)
                    ]
