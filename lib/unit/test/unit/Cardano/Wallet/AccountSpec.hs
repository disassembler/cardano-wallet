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
    , createAccountMigrationPlan
    , createWallet
    , listAccountAddresses
    , listTransactions
    , listWalletAccounts
    )
import Cardano.Wallet.Address.Derivation
    ( DerivationIndex (..)
    , Index (..)
    , PaymentAddress (..)
    )
import Cardano.Wallet.Address.Derivation.Shelley
    ( ShelleyKey
    , generateKeyFromSeed
    )
import Cardano.Wallet.Address.Discovery
    ( ChangeAddressMode (..)
    , GenChange (..)
    , IsOurs (..)
    , KnownAddresses (..)
    )
import Cardano.Wallet.Address.Discovery.Sequential
    ( SeqState
    , defaultAddressPoolGap
    , purposeCIP1852
    )
import Cardano.Wallet.Address.Keys.SequentialAny
    ( mkSeqStateForAccount
    , mkSeqStateFromRootXPrv
    )
import Cardano.Wallet.Balance.Migration
    ( MigrationPlan (..)
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
import Cardano.Wallet.Network
    ( NetworkLayer (..)
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
    , SNetworkId (..)
    )
import Cardano.Wallet.Primitive.Passphrase.Types
    ( Passphrase (..)
    )
import Cardano.Wallet.Primitive.Types
    ( SortOrder (..)
    , WalletId (..)
    , WalletName (..)
    )
import Cardano.Wallet.Primitive.Types.Credentials
    ( RootCredentials (..)
    )
import Cardano.Wallet.Read.PParams
    ( mockPParamsConway
    )
import Cardano.Wallet.Shelley.Transaction
    ( newTransactionLayer
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
import Data.Maybe
    ( isJust
    , isNothing
    )
import Data.Word
    ( Word32
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , pendingWith
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
    )
import Test.QuickCheck
    ( generate
    )

import qualified Cardano.Api as Cardano
import qualified Cardano.Wallet.Read as Read
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

    -- Group A: Path lookup correctness
    describe "path lookup (isOurs)" $ do
        it "account 1H SeqState recognises its own addresses with correct account index"
            testIsOursReturnsAccountIndexInPath
        it "account 0H SeqState does not recognise account 1H addresses"
            testAccount0HDoesNotRecognize1HAddresses

    -- Group B: Transaction history isolation
    describe "transaction history" $ do
        it "listTransactions returns empty for a fresh wallet"
            testListTransactionsEmptyForFreshWallet
        it "per-account transaction history is isolated (not yet implemented)" $
            pendingWith
                "listWalletAccountTransactionsH returns [] for non-0H accounts; \
                \mkTxMetaEntity hardcodes accountIndex=0 and readTransactions has no \
                \account filter — see implementation tasks"

    -- Group C: Consolidation plan
    describe "createAccountMigrationPlan" $ do
        it "returns empty plan for fresh 0H account with no UTxO"
            testConsolidatePlanEmptyForFreshWallet
        it "returns empty plan for fresh 1H account with no UTxO"
            testConsolidatePlanEmptyForFreshNonDefaultAccount

    -- Group D: ChangeAddressMode
    describe "ChangeAddressMode" $ do
        it "IncreasingChangeAddresses generates distinct consecutive addresses"
            testIncreasingChangeAddressesAreDistinct
        it "SingleChangeAddress always returns the same address"
            testSingleChangeAddressIsAlwaysSame
        it "SingleExternalAddress uses the external chain (role index 0)"
            testSingleExternalAddressIsOnExternalChain

-- ---------------------------------------------------------------------------
-- Group: addWalletAccount / list / addresses / UTxO isolation
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Group A: Path lookup correctness
-- ---------------------------------------------------------------------------

-- | A SeqState built for account 1H correctly embeds 0x80000001 at path
-- position 2 (purpose / coinType / accountIx / role / addrIx).  This is the
-- invariant that 'buildAndSignTransaction's extraPathLookup relies on.
testIsOursReturnsAccountIndexInPath :: IO ()
testIsOursReturnsAccountIndexInPath = do
    mw <- SomeMnemonic <$> generate (genMnemonic @15)
    let xprv = generateKeyFromSeed (mw, Nothing) mempty
        seqSt1H =
            mkSeqStateForAccount
                ShelleyKeyS
                (Index 0x80000001)
                (RootCredentials xprv mempty)
                defaultAddressPoolGap
                IncreasingChangeAddresses
                :: SeqState 'Mainnet ShelleyKey
        addrs = knownAddresses seqSt1H
    -- Every pre-generated address should be recognised with account index 1H
    addrs `shouldSatisfy` (not . null)
    mapM_ (checkAddr seqSt1H) addrs
  where
    checkAddr seqSt (addr, _, path) = do
        -- isOurs should succeed (not Nothing)
        fst (isOurs addr seqSt) `shouldSatisfy` isJust
        -- Account index is at position 2 in the 5-element path
        (path NE.!! 2) `shouldBe` DerivationIndex 0x80000001

-- | Addresses derived for account 1H are NOT recognised by the 0H SeqState.
-- This documents why 'buildAndSignTransaction' needs the extraPathLookup
-- fallback for non-0H account inputs.
testAccount0HDoesNotRecognize1HAddresses :: IO ()
testAccount0HDoesNotRecognize1HAddresses = do
    mw <- SomeMnemonic <$> generate (genMnemonic @15)
    let xprv = generateKeyFromSeed (mw, Nothing) mempty
        seqSt0H =
            mkSeqStateFromRootXPrv
                ShelleyKeyS
                (RootCredentials xprv mempty)
                purposeCIP1852
                defaultAddressPoolGap
                IncreasingChangeAddresses
                :: SeqState 'Mainnet ShelleyKey
        seqSt1H =
            mkSeqStateForAccount
                ShelleyKeyS
                (Index 0x80000001)
                (RootCredentials xprv mempty)
                defaultAddressPoolGap
                IncreasingChangeAddresses
                :: SeqState 'Mainnet ShelleyKey
        addrs1H = [addr | (addr, _, _) <- knownAddresses seqSt1H]
    addrs1H `shouldSatisfy` (not . null)
    mapM_
        (\addr -> fst (isOurs addr seqSt0H) `shouldSatisfy` isNothing)
        addrs1H

-- ---------------------------------------------------------------------------
-- Group B: Transaction history (documenting existing behaviour)
-- ---------------------------------------------------------------------------

-- | 'listTransactions' on a brand-new wallet returns an empty list.
testListTransactionsEmptyForFreshWallet :: IO ()
testListTransactionsEmptyForFreshWallet =
    withFullWalletLayer $ \wl _pwd -> do
        result <-
            runExceptT
                $ listTransactions wl Nothing Nothing Nothing Ascending Nothing Nothing
        case result of
            Left e -> fail $ "listTransactions failed: " <> show e
            Right txs -> txs `shouldBe` []

-- ---------------------------------------------------------------------------
-- Group C: Consolidation plan
-- ---------------------------------------------------------------------------

-- | A fresh 0H account with no UTxO produces an empty migration plan.
testConsolidatePlanEmptyForFreshWallet :: IO ()
testConsolidatePlanEmptyForFreshWallet =
    withFullWalletLayer $ \wl _pwd -> do
        plan <- createAccountMigrationPlan wl (Index 0x80000000)
        null (selections plan) `shouldBe` True

-- | A freshly-added 1H account with no UTxO also produces an empty plan.
testConsolidatePlanEmptyForFreshNonDefaultAccount :: IO ()
testConsolidatePlanEmptyForFreshNonDefaultAccount =
    withFullWalletLayer $ \wl pwd -> do
        void $ runExceptT $ addWalletAccount wl (Index 0x80000001) pwd
        plan <- createAccountMigrationPlan wl (Index 0x80000001)
        null (selections plan) `shouldBe` True

-- ---------------------------------------------------------------------------
-- Group D: ChangeAddressMode
-- ---------------------------------------------------------------------------

-- | With 'IncreasingChangeAddresses', successive calls to 'genChange' produce
-- addresses on distinct internal-chain slots (the counter advances).
testIncreasingChangeAddressesAreDistinct :: IO ()
testIncreasingChangeAddressesAreDistinct = do
    mw <- SomeMnemonic <$> generate (genMnemonic @15)
    let xprv = generateKeyFromSeed (mw, Nothing) mempty
        seqSt =
            mkSeqStateFromRootXPrv
                ShelleyKeyS
                (RootCredentials xprv mempty)
                purposeCIP1852
                defaultAddressPoolGap
                IncreasingChangeAddresses
                :: SeqState 'Mainnet ShelleyKey
        (addr1, seqSt') = genChange (\k _ -> paymentAddress SMainnet k) seqSt
        (addr2, _) = genChange (\k _ -> paymentAddress SMainnet k) seqSt'
    addr1 `shouldNotBe` addr2

-- | With 'SingleChangeAddress', 'genChange' always returns the same address
-- regardless of how many times it is called.
testSingleChangeAddressIsAlwaysSame :: IO ()
testSingleChangeAddressIsAlwaysSame = do
    mw <- SomeMnemonic <$> generate (genMnemonic @15)
    let xprv = generateKeyFromSeed (mw, Nothing) mempty
        seqSt =
            mkSeqStateFromRootXPrv
                ShelleyKeyS
                (RootCredentials xprv mempty)
                purposeCIP1852
                defaultAddressPoolGap
                SingleChangeAddress
                :: SeqState 'Mainnet ShelleyKey
        (addr1, seqSt') = genChange (\k _ -> paymentAddress SMainnet k) seqSt
        (addr2, _) = genChange (\k _ -> paymentAddress SMainnet k) seqSt'
    addr1 `shouldBe` addr2

-- | With 'SingleExternalAddress', the change address is on the external chain
-- (role index 0 at path position 3), not the internal chain (role index 1).
testSingleExternalAddressIsOnExternalChain :: IO ()
testSingleExternalAddressIsOnExternalChain = do
    mw <- SomeMnemonic <$> generate (genMnemonic @15)
    let xprv = generateKeyFromSeed (mw, Nothing) mempty
        seqSt =
            mkSeqStateFromRootXPrv
                ShelleyKeyS
                (RootCredentials xprv mempty)
                purposeCIP1852
                defaultAddressPoolGap
                SingleExternalAddress
                :: SeqState 'Mainnet ShelleyKey
        (changeAddr, _) = genChange (\k _ -> paymentAddress SMainnet k) seqSt
        -- Look up the derivation path via isOurs
        mPath = fst (isOurs changeAddr seqSt)
    mPath `shouldSatisfy` isJust
    case mPath of
        Nothing -> pure ()
        Just path ->
            -- Role is at index 3 (purpose/coinType/account/role/addrIx)
            (path NE.!! 3) `shouldBe` DerivationIndex 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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
        walletInitState = InitialState seqState block0 RestorationPointAtGenesis
    params <- createWallet dummyNetworkParameters wid wname walletInitState
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

-- | Like 'withShelleyWalletLayer' but supplies a network layer with working
-- 'timeInterpreter' and 'currentPParams', required for 'listTransactions' and
-- 'createAccountMigrationPlan'.
withFullWalletLayer
    :: ( WalletLayer IO (SeqState 'Mainnet ShelleyKey)
         -> Passphrase "user"
         -> IO a
       )
    -> IO a
withFullWalletLayer action = do
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
        wid = WalletId (hash ("shelley-account-spec-full" :: ByteString))
        wname = WalletName "AccountSpec full wallet"
        walletInitState = InitialState seqState block0 RestorationPointAtGenesis
        nl =
            dummyNetworkLayer
                { timeInterpreter = dummyTimeInterpreter
                , currentPParams = pure $ Read.EraValue mockPParamsConway
                , currentNodeTip = pure Read.GenesisTip
                }
        txLayer = newTransactionLayer ShelleyKeyS Cardano.Mainnet
    params <- createWallet dummyNetworkParameters wid wname walletInitState
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
                nl
                txLayer
                db'
    attachPrivateKeyFromPwd wl (xprv, pwd)
    action wl pwd
