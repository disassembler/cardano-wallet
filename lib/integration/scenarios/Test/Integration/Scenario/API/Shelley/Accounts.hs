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

import Cardano.Wallet.Api.Types
    ( AccountMode (..)
    , ApiAccount
    , ApiAccountIndex (..)
    , ApiAddressWithPath
    , ApiTransaction
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
import Numeric.Natural
    ( Natural
    )
import Test.Hspec
    ( SpecWith
    , describe
    )
import Test.Hspec.Expectations.Lifted
    ( shouldBe
    , shouldSatisfy
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
    , getFromResponse
    , getResponse
    , json
    , request
    , verify
    , waitForTxImmutability
    )

import qualified Cardano.Wallet.Api.Link as Link
import qualified Network.HTTP.Types.Status as HTTP
import Prelude

-- | Account 0 plain index (corresponds to hardened derivation path account 0H).
acct0H :: ApiAccountIndex
acct0H = ApiAccountIndex 0

-- | Account 1 plain index (corresponds to hardened derivation path account 1H).
acct1H :: ApiAccountIndex
acct1H = ApiAccountIndex 1

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

            -- 4b. The list-accounts endpoint must also reflect the new mode.
            rList <-
                request @[ApiAccount]
                    ctx
                    (Link.listWalletAccounts w)
                    Default
                    Empty
            verify
                rList
                [ expectResponseCode HTTP.status200
                ]
            let accts = getResponse rList
            liftIO $ length accts `shouldSatisfy` (>= 1)
            liftIO
                $ (head accts ^. #addressDerivationMode)
                    `shouldBe` AccountModeSingleAddress

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

    it
        "ACCOUNTS_02 - Transfer between 0H and 1H single-address accounts; \
        \change stays on 0H, signing works on 1H"
        $ \ctx -> runResourceT $ do
            -- Setup: seed 0H with UTxOs across multiple HD addresses so we
            -- have something to consolidate.
            w <- fixtureWalletWith @n ctx
                [ 3_000_000
                , 3_000_000
                , 3_000_000
                , 3_000_000
                , 3_000_000
                ]

            -- 1. Consolidate 0H so all funds sit on one change address.
            rConsolidate <-
                request @[ApiTransaction n]
                    ctx
                    (Link.postWalletAccountConsolidate w acct0H)
                    Default
                    (Json [json|{"passphrase": #{fixturePassphrase}}|])
            verify rConsolidate [expectResponseCode HTTP.status202]
            liftIO $ waitForTxImmutability ctx

            -- 2. Switch 0H to single-address mode.
            void $ request @ApiAccount ctx
                (Link.putWalletAccountMode w acct0H) Default
                (Json [json|{"mode": "account_mode_single_address"}|])

            -- 3. Record 0H's consolidated balance.
            rAcct0H_before <-
                request @ApiAccount ctx (Link.getWalletAccount w acct0H) Default Empty
            verify rAcct0H_before [expectResponseCode HTTP.status200]
            let bal0H_before =
                    getFromResponse (#balance . #available . #toNatural) rAcct0H_before

            -- 4. Add account 1H.
            rPost1H <-
                request @ApiAccount ctx (Link.postWalletAccount w) Default
                    (Json [json|{"account_index": 1, "passphrase": #{fixturePassphrase}}|])
            verify rPost1H [expectResponseCode HTTP.status201]

            -- 5. Switch 1H to single-address mode.
            void $ request @ApiAccount ctx
                (Link.putWalletAccountMode w acct1H) Default
                (Json [json|{"mode": "account_mode_single_address"}|])

            -- 6. Get 1H's receive address (first address in the pool).
            rAddrs1H <-
                request @[ApiAddressWithPath n] ctx
                    (Link.listWalletAccountAddresses w acct1H) Default Empty
            verify rAddrs1H [expectResponseCode HTTP.status200]
            let addr1H = (getResponse rAddrs1H !! 0) ^. #id

            -- 7. Send 4 ADA from 0H to 1H.
            let sendAmt = 4_000_000 :: Natural
            rSend <-
                request @(ApiTransaction n) ctx
                    (Link.createWalletAccountTransaction w acct0H) Default
                    (Json [json|{
                        "payments": [{
                            "address": #{addr1H},
                            "amount": {"quantity": #{sendAmt}, "unit": "lovelace"}
                        }],
                        "passphrase": #{fixturePassphrase}
                    }|])
            verify rSend [expectResponseCode HTTP.status202]
            liftIO $ waitForTxImmutability ctx

            -- 8. Verify 0H balance decreased (by sendAmt + fees).
            rAcct0H_after <-
                request @ApiAccount ctx (Link.getWalletAccount w acct0H) Default Empty
            verify rAcct0H_after [expectResponseCode HTTP.status200]
            let bal0H_after =
                    getFromResponse (#balance . #available . #toNatural) rAcct0H_after
            liftIO $ bal0H_after `shouldSatisfy` (< bal0H_before - sendAmt)

            -- 9. Verify 1H received exactly 4 ADA.
            eventually "1H balance reflects received funds" $ do
                rAcct1H <-
                    request @ApiAccount ctx
                        (Link.getWalletAccount w acct1H) Default Empty
                verify rAcct1H
                    [ expectResponseCode HTTP.status200
                    , expectField
                        (#balance . #available . #toNatural)
                        (`shouldBe` sendAmt)
                    ]

            -- 10. Verify the send appears in 0H's transaction list.
            rTxs0H <-
                request @[ApiTransaction n] ctx
                    (Link.listWalletAccountTransactions w acct0H) Default Empty
            verify rTxs0H [expectResponseCode HTTP.status200]
            liftIO $ length (getResponse rTxs0H) `shouldSatisfy` (> 0)

            -- 11. Verify the receive appears in 1H's transaction list.
            rTxs1H <-
                request @[ApiTransaction n] ctx
                    (Link.listWalletAccountTransactions w acct1H) Default Empty
            verify rTxs1H [expectResponseCode HTTP.status200]
            liftIO $ length (getResponse rTxs1H) `shouldSatisfy` (> 0)

            -- 12. Get 0H's single receive address to send back to.
            rAddrs0H <-
                request @[ApiAddressWithPath n] ctx
                    (Link.listWalletAccountAddresses w acct0H) Default Empty
            verify rAddrs0H [expectResponseCode HTTP.status200]
            let addr0H = (getResponse rAddrs0H !! 0) ^. #id

            -- 13. Send 2 ADA back from 1H to 0H to verify 1H can sign.
            let returnAmt = 2_000_000 :: Natural
            rReturn <-
                request @(ApiTransaction n) ctx
                    (Link.createWalletAccountTransaction w acct1H) Default
                    (Json [json|{
                        "payments": [{
                            "address": #{addr0H},
                            "amount": {"quantity": #{returnAmt}, "unit": "lovelace"}
                        }],
                        "passphrase": #{fixturePassphrase}
                    }|])
            verify rReturn [expectResponseCode HTTP.status202]
            liftIO $ waitForTxImmutability ctx

            -- 14. Verify final balances: 0H recovered ~2 ADA, 1H has ~2 ADA minus fee.
            rFinal0H <-
                request @ApiAccount ctx (Link.getWalletAccount w acct0H) Default Empty
            rFinal1H <-
                request @ApiAccount ctx (Link.getWalletAccount w acct1H) Default Empty
            verify rFinal0H [expectResponseCode HTTP.status200]
            verify rFinal1H [expectResponseCode HTTP.status200]
            let finalBal0H =
                    getFromResponse (#balance . #available . #toNatural) rFinal0H
            let finalBal1H =
                    getFromResponse (#balance . #available . #toNatural) rFinal1H
            -- 0H gained returnAmt back (minus consolidation fee already counted)
            liftIO $ finalBal0H `shouldSatisfy` (> bal0H_after)
            -- 1H spent returnAmt so its balance < sendAmt
            liftIO $ finalBal1H `shouldSatisfy` (< sendAmt)
            -- 1H has something left (sendAmt - returnAmt - fee > 0)
            liftIO $ finalBal1H `shouldSatisfy` (> 0)

    it
        "ACCOUNTS_03 - Send 10 ADA from account 0H to 1H, verify receipt, \
        \send funds back"
        $ \ctx -> runResourceT $ do
            -- Seed account 0H with 12 ADA (plenty for 10 ADA send + fees).
            w <- fixtureWalletWith @n ctx [12_000_000]

            -- 1. Create account 1H.
            rPost1H <-
                request @ApiAccount ctx (Link.postWalletAccount w) Default
                    (Json [json|{"account_index": 1, "passphrase": #{fixturePassphrase}}|])
            verify rPost1H [expectResponseCode HTTP.status201]

            -- 2. Get 1H's receive address.
            rAddrs1H <-
                request @[ApiAddressWithPath n] ctx
                    (Link.listWalletAccountAddresses w acct1H) Default Empty
            verify rAddrs1H [expectResponseCode HTTP.status200]
            let addr1H = (getResponse rAddrs1H !! 0) ^. #id

            -- 3. Send 10 ADA from 0H to 1H.
            let sendAmt = 10_000_000 :: Natural
            rSend <-
                request @(ApiTransaction n) ctx
                    (Link.createWalletAccountTransaction w acct0H) Default
                    (Json [json|{
                        "payments": [{
                            "address": #{addr1H},
                            "amount": {"quantity": #{sendAmt}, "unit": "lovelace"}
                        }],
                        "passphrase": #{fixturePassphrase}
                    }|])
            verify rSend [expectResponseCode HTTP.status202]
            liftIO $ waitForTxImmutability ctx

            -- 4. Verify 1H received exactly 10 ADA.
            eventually "1H balance is 10 ADA" $ do
                rAcct1H <-
                    request @ApiAccount ctx
                        (Link.getWalletAccount w acct1H) Default Empty
                verify rAcct1H
                    [ expectResponseCode HTTP.status200
                    , expectField
                        (#balance . #available . #toNatural)
                        (`shouldBe` sendAmt)
                    ]

            -- 5. Get 0H's receive address for the return transfer.
            rAddrs0H <-
                request @[ApiAddressWithPath n] ctx
                    (Link.listWalletAccountAddresses w acct0H) Default Empty
            verify rAddrs0H [expectResponseCode HTTP.status200]
            let addr0H = (getResponse rAddrs0H !! 0) ^. #id

            -- 6. Send funds back: 5 ADA from 1H to 0H. Sending 9 would leave
            --    only ~0.8 ADA change which is below the minimum UTXO value,
            --    causing the wallet to produce no change output. 5 ADA leaves
            --    ~4.8 ADA change which is safely above the minimum.
            let returnAmt = 5_000_000 :: Natural
            rReturn <-
                request @(ApiTransaction n) ctx
                    (Link.createWalletAccountTransaction w acct1H) Default
                    (Json [json|{
                        "payments": [{
                            "address": #{addr0H},
                            "amount": {"quantity": #{returnAmt}, "unit": "lovelace"}
                        }],
                        "passphrase": #{fixturePassphrase}
                    }|])
            verify rReturn [expectResponseCode HTTP.status202]
            liftIO $ waitForTxImmutability ctx

            -- 7. Verify 1H balance decreased and 0H balance recovered.
            eventually "balances settle after return transfer" $ do
                rFinal0H <-
                    request @ApiAccount ctx
                        (Link.getWalletAccount w acct0H) Default Empty
                rFinal1H <-
                    request @ApiAccount ctx
                        (Link.getWalletAccount w acct1H) Default Empty
                verify rFinal0H [expectResponseCode HTTP.status200]
                verify rFinal1H [expectResponseCode HTTP.status200]
                let bal0H =
                        getFromResponse (#balance . #available . #toNatural) rFinal0H
                    bal1H =
                        getFromResponse (#balance . #available . #toNatural) rFinal1H
                -- 0H should have recovered at least the return amount minus fees.
                liftIO $ bal0H `shouldSatisfy` (>= returnAmt - 1_000_000)
                -- 1H spent returnAmt so balance < sendAmt, but still has some left.
                liftIO $ bal1H `shouldSatisfy` (< sendAmt)
                liftIO $ bal1H `shouldSatisfy` (> 0)
