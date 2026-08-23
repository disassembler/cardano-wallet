{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Wallet.AccountSpec (spec) where

import Prelude

import Cardano.BM.Data.Tracer
    ( nullTracer
    )
import Cardano.Mnemonic
    ( SomeMnemonic (..)
    )
import Cardano.Wallet
    ( ErrAddAccount (..)
    , InitialState (..)
    , WalletLayer (..)
    , addWalletAccount
    , attachPrivateKeyFromPwd
    , createWallet
    , listAccountAddresses
    , listWalletAccounts
    )
import Cardano.Wallet.Address.Derivation
    ( DerivationIndex (..)
    , Index (..)
    )
import Cardano.Wallet.Address.Derivation.Shelley
    ( ShelleyKey
    , generateKeyFromSeed
    )
import Cardano.Wallet.Address.Discovery
    ( ChangeAddressMode (..)
    )
import Cardano.Wallet.Address.Discovery.Sequential
    ( SeqState
    , defaultAddressPoolGap
    , purposeCIP1852
    )
import Cardano.Wallet.Address.Keys.SequentialAny
    ( mkSeqStateFromRootXPrv
    )
import Cardano.Wallet.DB
    ( hoistDBLayer
    )
import Cardano.Wallet.DB.Layer
    ( newBootDBLayerInMemory
    )
import Cardano.Wallet.DummyTarget.Primitive.Types
    ( block0
    , dummyNetworkLayer
    , dummyNetworkParameters
    , dummyTimeInterpreter
    )
import Cardano.Wallet.Flavor
    ( KeyFlavorS (..)
    , WalletFlavorS (..)
    )
import Cardano.Wallet.Gen
    ( genMnemonic
    )
import Cardano.Wallet.Network.RestorationMode
    ( RestorationPoint (..)
    )
import Cardano.Wallet.Primitive.NetworkId
    ( NetworkDiscriminant (..)
    )
import Cardano.Wallet.Primitive.Model
    ( getState
    )
import Cardano.Wallet.Primitive.Passphrase.Types
    ( Passphrase (..)
    )
import Cardano.Wallet.Primitive.Types
    ( WalletId (..)
    , WalletName (..)
    )
import Cardano.Wallet.Primitive.Types.Credentials
    ( RootCredentials (..)
    )
import Control.Monad
    ( void
    )
import Control.Monad.IO.Class
    ( liftIO
    )
import Control.Monad.Trans.Except
    ( runExceptT
    )
import Cryptography.Hash.Core
    ( hash
    )
import Data.ByteString
    ( ByteString
    )
import Data.Word
    ( Word32
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )
import Test.QuickCheck
    ( generate
    )

import qualified Data.ByteArray as BA
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set

spec :: Spec
spec = do
    describe "addWalletAccount" $ do
        it "succeeds when adding a fresh hardened account (3H)"
            testAddFreshAccount
        it "returns ErrAddAccountDuplicate when adding default account (0H)"
            testAdd0HReturnsDuplicate
        it "returns ErrAddAccountDuplicate when adding the same index twice"
            testAddSameIndexTwice

    describe "listWalletAccounts" $
        it "returns accounts in ascending index order including 0H"
            testListAccountsOrder

    describe "listAccountAddresses" $
        it "addresses for different accounts have disjoint derivation paths"
            testAddressPathIsolation

    describe "readAccountUTxO" $
        it "different accounts have disjoint address sets (structural isolation)"
            testCrossAccountUtxoIsolation

-- | Adding 3H to a fresh wallet succeeds.
testAddFreshAccount :: IO ()
testAddFreshAccount = withShelleyWalletLayer $ \wl pwd -> do
    result <- runExceptT $ addWalletAccount wl (Index 0x80000003) pwd
    result `shouldBe` Right ()

-- | Adding 0H always returns 'ErrAddAccountDuplicate' because 0H is the
-- default account present in every newly created wallet.
testAdd0HReturnsDuplicate :: IO ()
testAdd0HReturnsDuplicate = withShelleyWalletLayer $ \wl pwd -> do
    result <- runExceptT $ addWalletAccount wl (Index 0x80000000) pwd
    result `shouldBe` Left ErrAddAccountDuplicate

-- | Adding the same non-default account twice returns 'ErrAddAccountDuplicate'
-- on the second call.
testAddSameIndexTwice :: IO ()
testAddSameIndexTwice = withShelleyWalletLayer $ \wl pwd -> do
    void $ runExceptT $ addWalletAccount wl (Index 0x80000003) pwd
    result <- runExceptT $ addWalletAccount wl (Index 0x80000003) pwd
    result `shouldBe` Left ErrAddAccountDuplicate

-- | US5: listWalletAccounts returns 0H, 1H, 5H in ascending order.
testListAccountsOrder :: IO ()
testListAccountsOrder = withShelleyWalletLayer $ \wl pwd -> do
    void $ runExceptT $ addWalletAccount wl (Index 0x80000001) pwd
    void $ runExceptT $ addWalletAccount wl (Index 0x80000005) pwd
    accounts <- listWalletAccounts wl
    let minIx = 0x80000000 :: Word32
        toHardened w = if w == 0 then minIx else w
    map toHardened accounts `shouldBe` [0x80000000, 0x80000001, 0x80000005]

-- | US4: addresses for account 1H have path prefix 1852H/1815H/1H; addresses
-- for account 2H have path prefix 1852H/1815H/2H; no overlap between the sets.
testAddressPathIsolation :: IO ()
testAddressPathIsolation = withShelleyWalletLayer $ \wl pwd -> do
    void $ runExceptT $ addWalletAccount wl (Index 0x80000001) pwd
    void $ runExceptT $ addWalletAccount wl (Index 0x80000002) pwd
    addrs1H <- listAccountAddresses wl (const Just) (Index 0x80000001)
    addrs2H <- listAccountAddresses wl (const Just) (Index 0x80000002)
    let accountIxOf (_, _, path) = path NE.!! 2
    -- All 1H addresses have account derivation index 1H
    all ((== DerivationIndex 0x80000001) . accountIxOf) addrs1H
        `shouldBe` True
    -- All 2H addresses have account derivation index 2H
    all ((== DerivationIndex 0x80000002) . accountIxOf) addrs2H
        `shouldBe` True
    -- Address sets from different accounts are disjoint
    let addrSet1H = Set.fromList [a | (a, _, _) <- addrs1H]
        addrSet2H = Set.fromList [a | (a, _, _) <- addrs2H]
    Set.null (Set.intersection addrSet1H addrSet2H) `shouldBe` True

-- | US3: account 0H and account 1H have structurally disjoint address pools.
-- An address generated by one account cannot belong to the other.
-- NOTE: readAccountUTxO requires a live network layer (currentNodeTip) and
-- is covered by integration tests; here we verify structural address isolation.
testCrossAccountUtxoIsolation :: IO ()
testCrossAccountUtxoIsolation = withShelleyWalletLayer $ \wl pwd -> do
    void $ runExceptT $ addWalletAccount wl (Index 0x80000001) pwd
    addrs0H <- listAccountAddresses wl (const Just) (Index 0x80000000)
    addrs1H <- listAccountAddresses wl (const Just) (Index 0x80000001)
    -- Both pools are non-empty (initial address pool gap has addresses)
    length addrs0H `shouldSatisfy` (> 0)
    length addrs1H `shouldSatisfy` (> 0)
    -- The address sets are disjoint (different account keys produce different addresses)
    let addrSet0H = Set.fromList [a | (a, _, _) <- addrs0H]
        addrSet1H = Set.fromList [a | (a, _, _) <- addrs1H]
    Set.null (Set.intersection addrSet0H addrSet1H) `shouldBe` True

-- | Create an in-memory Shelley wallet layer and run an action with it.
-- The root key is attached so that 'addWalletAccount' can decrypt it.
withShelleyWalletLayer
    :: ( WalletLayer IO (SeqState 'Mainnet ShelleyKey)
         -> Passphrase "user"
         -> IO a
       )
    -> IO a
withShelleyWalletLayer action = do
    mw <- SomeMnemonic <$> generate (genMnemonic @15)
    let pwd = Passphrase (BA.convert ("test-passphrase-0000" :: ByteString))
        xprv = generateKeyFromSeed (mw, Nothing) mempty
        seqState =
            mkSeqStateFromRootXPrv
                ShelleyKeyS
                (RootCredentials xprv mempty)
                purposeCIP1852
                defaultAddressPoolGap
                IncreasingChangeAddresses
        wid = WalletId (hash ("shelley-account-spec" :: ByteString))
        wname = WalletName "AccountSpec test wallet"
        initialState = InitialState seqState block0 RestorationPointAtGenesis
    params <- createWallet dummyNetworkParameters wid wname initialState
    (_kill, db) <-
        newBootDBLayerInMemory
            ShelleyWallet
            nullTracer
            dummyTimeInterpreter
            wid
            params
    let db' = hoistDBLayer liftIO db
        wl =
            WalletLayer
                nullTracer
                (block0, dummyNetworkParameters)
                dummyNetworkLayer
                (error "AccountSpec: transactionLayer not used")
                db'
    attachPrivateKeyFromPwd wl (xprv, pwd)
    action wl pwd
