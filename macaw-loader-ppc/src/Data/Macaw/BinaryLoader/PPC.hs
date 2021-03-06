{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Data.Macaw.BinaryLoader.PPC
  ( PPCLoadException(..)
  , HasTOC(..)
  )
where

import qualified Control.Monad.Catch as X
import qualified Data.ElfEdit as E
import qualified Data.List.NonEmpty as NEL
import qualified Data.Macaw.BinaryLoader as BL
import qualified Data.Macaw.BinaryLoader.PPC.ELF as BE
import qualified Data.Macaw.BinaryLoader.PPC.TOC as TOC
import qualified Data.Macaw.CFG as MC
import qualified Data.Macaw.Memory.ElfLoader as EL
import qualified Data.Macaw.Memory.LoadCommon as LC
import           Data.Maybe ( mapMaybe )
import           Data.Typeable ( Typeable )
import           GHC.TypeLits
import qualified SemMC.Architecture.PPC32 as PPC32
import qualified SemMC.Architecture.PPC64 as PPC64

class HasTOC arch binFmt where
  getTOC :: BL.LoadedBinary arch binFmt -> TOC.TOC (MC.ArchAddrWidth arch)

data PPCElfData w = PPCElfData { elf :: E.Elf w
                               , memSymbols :: [EL.MemSymbol w]
                               }

-- NOTE: This funny constraint is necessary because we don't have access to the
-- PPCReg type here.  If we could import that type and get its associated
-- instances, this information would be apparent to the compiler, but we can't
-- import it because it is in a package we can't depend on.  Anywhere we use
-- this instance, the compiler will ensure that the assertion is actually true.
instance (MC.ArchAddrWidth PPC32.PPC ~ 32) => BL.BinaryLoader PPC32.PPC (E.Elf 32) where
  type ArchBinaryData PPC32.PPC (E.Elf 32) = TOC.TOC 32
  type BinaryFormatData PPC32.PPC (E.Elf 32) = PPCElfData 32
  type Diagnostic PPC32.PPC (E.Elf 32) = EL.MemLoadWarning
  loadBinary = loadPPCBinary BL.Elf32Repr
  entryPoints = ppcEntryPoints

instance (MC.ArchAddrWidth PPC32.PPC ~ 32) => HasTOC PPC32.PPC (E.Elf 32) where
  getTOC = BL.archBinaryData

instance (MC.ArchAddrWidth PPC64.PPC ~ 64) => BL.BinaryLoader PPC64.PPC (E.Elf 64) where
  type ArchBinaryData PPC64.PPC (E.Elf 64)  = TOC.TOC 64
  type BinaryFormatData PPC64.PPC (E.Elf 64) = PPCElfData 64
  type Diagnostic PPC64.PPC (E.Elf 64) = EL.MemLoadWarning
  loadBinary = loadPPCBinary BL.Elf64Repr
  entryPoints = ppcEntryPoints

instance (MC.ArchAddrWidth PPC64.PPC ~ 64) => HasTOC PPC64.PPC (E.Elf 64) where
  getTOC = BL.archBinaryData

ppcEntryPoints :: (X.MonadThrow m,
                   MC.MemWidth w,
                   Integral (E.ElfWordType w),
                   MC.ArchAddrWidth ppc ~ w,
                   BL.ArchBinaryData ppc (E.Elf w) ~ TOC.TOC w,
                   BL.BinaryFormatData ppc (E.Elf w) ~ PPCElfData w)
               => BL.LoadedBinary ppc (E.Elf w)
               -> m (NEL.NonEmpty (MC.MemSegmentOff w))
ppcEntryPoints loadedBinary = do
  entryAddr <- liftMemErr PPCElfMemoryError
               (MC.readAddr mem (BL.memoryEndianness loadedBinary) tocEntryAbsAddr)
  absEntryAddr <- liftMaybe (PPCInvalidAbsoluteAddress entryAddr) (MC.asSegmentOff mem entryAddr)
  let otherEntries = mapMaybe (MC.asSegmentOff mem) (TOC.entryPoints toc)
  return (absEntryAddr NEL.:| otherEntries)
  where
    tocEntryAddr = E.elfEntry (elf (BL.binaryFormatData loadedBinary))
    tocEntryAbsAddr :: EL.MemWidth w => MC.MemAddr w
    tocEntryAbsAddr = MC.absoluteAddr (MC.memWord (fromIntegral tocEntryAddr))
    toc = BL.archBinaryData loadedBinary
    mem = BL.memoryImage loadedBinary

liftMaybe :: (X.Exception e, X.MonadThrow m) => e -> Maybe a -> m a
liftMaybe exn a =
  case a of
    Nothing -> X.throwM exn
    Just res -> return res

liftMemErr :: (X.Exception e, X.MonadThrow m) => (t -> e) -> Either t a -> m a
liftMemErr exn a =
  case a of
    Left err -> X.throwM (exn err)
    Right res -> return res

loadPPCBinary :: (X.MonadThrow m,
                  BL.ArchBinaryData ppc (E.Elf w) ~ TOC.TOC w,
                  BL.BinaryFormatData ppc (E.Elf w) ~ PPCElfData w,
                  MC.ArchAddrWidth ppc ~ w,
                  BL.Diagnostic ppc (E.Elf w) ~ EL.MemLoadWarning,
                  MC.MemWidth w,
                  Typeable w,
                  KnownNat w)
              => BL.BinaryRepr (E.Elf w)
              -> LC.LoadOptions
              -> E.Elf w
              -> m (BL.LoadedBinary ppc (E.Elf w))
loadPPCBinary binRep lopts e = do
  case EL.memoryForElf lopts e of
    Left err -> X.throwM (PPCElfLoadError err)
    Right (mem, symbols, warnings, _) ->
      case BE.parseTOC e of
        Left err -> X.throwM (PPCTOCLoadError err)
        Right toc ->
          return BL.LoadedBinary { BL.memoryImage = mem
                                 , BL.memoryEndianness = MC.BigEndian
                                 , BL.archBinaryData = toc
                                 , BL.binaryFormatData =
                                   PPCElfData { elf = e
                                              , memSymbols = symbols
                                              }
                                 , BL.loadDiagnostics = warnings
                                 , BL.binaryRepr = binRep
                                 }

data PPCLoadException = PPCElfLoadError String
                      | PPCTOCLoadError X.SomeException
                      | forall w . (MC.MemWidth w) => PPCElfMemoryError (MC.MemoryError w)
                      | forall w . (MC.MemWidth w) => PPCInvalidAbsoluteAddress (MC.MemAddr w)

deriving instance Show PPCLoadException

instance X.Exception PPCLoadException
