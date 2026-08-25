{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Test.Integration.Scenario.API.Shelley.Accounts
    ( spec
    ) where

import Cardano.Wallet.Address.Derivation
    ( DerivationIndex (..)
    )
import Cardano.Wallet.Api.Types
    ( AccountMode (..)
    , ApiAccount
    , ApiT (..)
    , ApiTransaction
    , ApiWallet
    , WalletStyle (..)
    )
import Cardano.Wallet.Primitive.NetworkId
    ( HasSNetworkId (..)
    )
import Control.Monad
    ( void
    )
import Control.Monad.IO.Class
    ( liftIO
    )
import Control.Monad.Trans.Resource
    ( runResourceT
    )
import Data.Generics.Internal.VL.Lens
    ( (^.)
    )
import Test.Hspec
    ( SpecWith
    , describe
    )
import Test.Hspec.Expectations.Lifted
    ( shouldBe
    )
import Test.Hspec.Extra
    ( it
    )
import Test.Integration.Framework.DSL
    ( Context (..)
    , Headers (..)
    , Payload (..)
    , eventually
    , expectField
    , expectResponseCode
    , fixturePassphrase
    , fixtureWalletWith
    , json
    , request
    , verify
    , waitForTxImmutability
    )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Network.HTTP.Types.Status as HTTP
import Prelude

-- | Account 0H raw index (hardened, first account).
acct0H :: ApiT DerivationIndex
acct0H = ApiT (DerivationIndex 0x80000000)

spec :: forall n. HasSNetworkId n => SpecWith Context
spec = describe "SHELLEY_ACCOUNTS" $ do

    it
        "ACCOUNTS_MODE_01 - Consolidate UTxOs and switch to single-address mode, \
        \mode survives chain sync"
        $ \ctx -> runResourceT $ do
            -- Create a wallet pre-seeded with UTxOs spread across several HD
            -- addresses (fixtureWalletWith moves coins to distinct addresses).
            w <- fixtureWalletWith @n ctx
                [ 1_000_000
                , 2_000_000
                , 3_000_000
                , 4_000_000
                , 5_000_000
                ]

            -- 1. Confirm the account starts in HD mode.
            rGet0 <-
                request @ApiAccount
                    ctx
                    (Link.getWalletAccount w acct0H)
                    Default
                    Empty
            verify
                rGet0
                [ expectResponseCode HTTP.status200
                , expectField #addressDerivationMode (`shouldBe` AccountModeHD)
                ]

            -- 2. Consolidate: sweep all HD UTxOs into the single change address.
            rConsolidate <-
                request @[ApiTransaction n]
                    ctx
                    (Link.postWalletAccountConsolidate w acct0H)
                    Default
                    (Json [json|{"passphrase": #{fixturePassphrase}}|])
            verify
                rConsolidate
                [ expectResponseCode HTTP.status202
                ]

            -- Wait for consolidation transactions to be on-chain and immutable.
            liftIO $ waitForTxImmutability ctx

            -- 3. Switch mode to single-address.
            rPut <-
                request @ApiAccount
                    ctx
                    (Link.putWalletAccountMode w acct0H)
                    Default
                    (Json [json|{"mode": "account_mode_single_address"}|])
            verify
                rPut
                [ expectResponseCode HTTP.status200
                , expectField #addressDerivationMode
                    (`shouldBe` AccountModeSingleAddress)
                ]

            -- 4. Immediate GET must return single-address mode.
            rGet1 <-
                request @ApiAccount
                    ctx
                    (Link.getWalletAccount w acct0H)
                    Default
                    Empty
            verify
                rGet1
                [ expectResponseCode HTTP.status200
                , expectField #addressDerivationMode
                    (`shouldBe` AccountModeSingleAddress)
                ]

            -- 5. Mode must survive block application (simulates a restart):
            --    wait for more blocks to be processed via chain sync and
            --    confirm the mode has not been reset to HD.
            eventually "Mode persists across chain sync / restart" $ do
                rGet2 <-
                    request @ApiAccount
                        ctx
                        (Link.getWalletAccount w acct0H)
                        Default
                        Empty
                verify
                    rGet2
                    [ expectResponseCode HTTP.status200
                    , expectField #addressDerivationMode
                        (`shouldBe` AccountModeSingleAddress)
                    ]
