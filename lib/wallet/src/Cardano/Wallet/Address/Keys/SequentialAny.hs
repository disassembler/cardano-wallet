{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Wallet.Address.Keys.SequentialAny
    ( mkSeqAnyState
    , mkSeqStateFromRootXPrv
    , mkSeqStateForAccount
    )
where

import Cardano.Wallet.Address.Derivation
    ( Depth (..)
    , DerivationType (..)
    , HardDerivation (..)
    , Index (..)
    )
import Cardano.Wallet.Address.Derivation.Byron
    ( ByronKey (..)
    )
import Cardano.Wallet.Address.Derivation.MintBurn
    ( derivePolicyPrivateKey
    )
import Cardano.Wallet.Address.Derivation.SharedKey
    ( SharedKey (..)
    )
import Cardano.Wallet.Address.Discovery
    ( ChangeAddressMode (..)
    )
import Cardano.Wallet.Address.Discovery.Sequential
    ( AddressPoolGap
    , DerivationPrefix (..)
    , SeqState (..)
    , SupportsDiscovery
    , coinTypeAda
    , mkSeqStateFromAccountXPub
    , purposeCIP1852
    )
import Cardano.Wallet.Address.Discovery.SequentialAny
    ( SeqAnyState (..)
    )
import Cardano.Wallet.Address.Keys.WalletKey
    ( getRawKey
    , liftRawKey
    , publicKey
    )
import Cardano.Wallet.Flavor
    ( Excluding
    , KeyFlavorS
    )
import Cardano.Wallet.Primitive.Types.Credentials
    ( ClearCredentials
    , RootCredentials (..)
    )
import GHC.TypeLits
    ( Nat
    )
import Prelude

-- | Initialize the HD random address discovery state from a root key and RNG
-- seed.
--
-- The type parameter is expected to be a ratio of addresses we ought to simply
-- recognize as ours. It is expressed in per-myriad, so "1" means 0.01%,
-- "100" means 1% and 10000 means 100%.
mkSeqAnyState
    :: forall (p :: Nat) n k
     . ( SupportsDiscovery n k
       , Excluding '[SharedKey, ByronKey] k
       )
    => KeyFlavorS k
    -> ClearCredentials k
    -> Index 'Hardened 'PurposeK
    -> AddressPoolGap
    -> SeqAnyState n k p
mkSeqAnyState kF credentials purpose poolGap =
    SeqAnyState
        { innerState =
            mkSeqStateFromRootXPrv
                kF
                credentials
                purpose
                poolGap
                IncreasingChangeAddresses
        }

-- | Construct a Sequential state for a wallet
-- from root private key and password.
mkSeqStateFromRootXPrv
    :: forall n k
     . ( SupportsDiscovery n k
       , Excluding '[ByronKey, SharedKey] k
       )
    => KeyFlavorS k
    -> ClearCredentials k
    -> Index 'Hardened 'PurposeK
    -> AddressPoolGap
    -> ChangeAddressMode
    -> SeqState n k
mkSeqStateFromRootXPrv kF (RootCredentials rootXPrv pwd) =
    mkSeqStateFromAccountXPub
        (publicKey kF $ deriveAccountPrivateKey pwd rootXPrv minBound)
        $ Just
        $ publicKey kF
        $ liftRawKey kF
        $ derivePolicyPrivateKey pwd (getRawKey kF rootXPrv) minBound

-- | Construct a 'SeqState' for a specific hardened account index, using the
-- Shelley (CIP-1852) purpose.  Unlike 'mkSeqStateFromRootXPrv', the caller
-- provides the account index explicitly — enabling wallets with multiple
-- accounts derived from the same root key.
mkSeqStateForAccount
    :: forall n k
     . ( SupportsDiscovery n k
       , Excluding '[ByronKey, SharedKey] k
       )
    => KeyFlavorS k
    -> Index 'Hardened 'AccountK
    -> ClearCredentials k
    -> AddressPoolGap
    -> ChangeAddressMode
    -> SeqState n k
mkSeqStateForAccount
    kF
    accountIx
    (RootCredentials rootXPrv pwd)
    gap
    changeMode =
        let base :: SeqState n k
            base =
                mkSeqStateFromAccountXPub @n
                    (publicKey kF $ deriveAccountPrivateKey pwd rootXPrv accountIx)
                    ( Just
                        $ publicKey kF
                        $ liftRawKey kF
                        $ derivePolicyPrivateKey pwd (getRawKey kF rootXPrv) minBound
                    )
                    purposeCIP1852
                    gap
                    changeMode
        in  base
                { derivationPrefix =
                    DerivationPrefix (purposeCIP1852, coinTypeAda, accountIx)
                }
