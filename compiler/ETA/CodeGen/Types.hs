{-# LANGUAGE OverloadedStrings #-}
module ETA.CodeGen.Types
  (TopLevelFlag(..),
   RepArity,
   CgLoc(..),
   CgIdInfo(..),
   NonVoid(..),
   LambdaFormInfo(..),
   StandardFormInfo(..),
   ArgFVDescr(..),
   RecFlag(..),
   Sequel(..),
   FunRecInfo,
   FunRecMap,
   CallPattern,
   SelfLoopInfo,
   CgBindings,
   RecIndexes,
   RecInfo,
   storeDefault,
   locArgRep,
   mkRepLocDirect,
   mkLocDirect,
   newLocDirect,
   mkLocLocal,
   mkLocArg,
   getNonVoidFts,
   enterMethod,
   evaluateMethod,
   loadLoc,
   storeLoc,
   locFt,
   isRec,
   isNonRec,
   mkCgIdInfo,
   mkCgIdInfoWithLoc,
   unsafeStripNV,
   nonVoidIds,
   getJavaInfo,
   getNonVoids,
   isLFThunk,
   lfFieldType,
   lfStaticThunk)
where

import ETA.BasicTypes.Id
import ETA.BasicTypes.BasicTypes
import ETA.BasicTypes.VarEnv
import ETA.BasicTypes.DataCon
import ETA.Types.TyCon
import ETA.BasicTypes.Name
import ETA.Main.DynFlags
import Codec.JVM
import ETA.CodeGen.Name
import ETA.CodeGen.Rts
import ETA.CodeGen.ArgRep
import ETA.Debug
import ETA.Util
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Monoid ((<>))

type SelfLoopInfo = (Id, Label, [CgLoc])

data Sequel
  = Return
  | AssignTo [CgLoc]

data CgLoc = LocLocal Bool FieldType !Int
           | LocStatic FieldType Text Text
           | LocField Bool FieldType Text Text
           | LocDirect Bool FieldType Code
           | LocLne Label Int CgLoc [CgLoc]
           | LocMask FieldType CgLoc

instance Outputable CgLoc where
  ppr (LocLocal isClosure ft int)
    = str "local:" <+> ppr isClosure <+> str (show ft) <+> ppr int
  ppr (LocStatic ft mod cls)
    = str "static:" <+> str (show ft) <+> str (T.unpack mod) <+> str (T.unpack cls)
  ppr (LocField isClosure ft mod cls)
    = str "field:" <+> ppr isClosure
    <+> str (show ft) <+> str (T.unpack mod) <+> str (T.unpack cls)
  ppr (LocDirect isClosure ft _) = str "direct:" <+> ppr isClosure <+> str (show ft)
  ppr (LocLne (Label l) target cgLoc cgLocs)
    = str "lne: label:" <+> ppr l <+> str "target:" <+> ppr target <+>
      str "targetLoc:" <+> ppr cgLoc <+> str "argLocs:" <+> hcat (map ppr cgLocs)

mkLocDirect :: Bool -> (FieldType, Code) -> CgLoc
mkLocDirect isClosure (ft, code) = LocDirect isClosure ft code

mkLocLocal :: Bool -> FieldType -> Int -> CgLoc
mkLocLocal isClosure ft int = LocLocal isClosure ft int

newLocDirect :: NonVoid Id -> Code -> CgLoc
newLocDirect (NonVoid id) code =
  mkLocDirect (isGcPtrRep rep) (primRepFieldType rep, code)
  where rep = idPrimRep id

mkLocArg :: NonVoid Id -> Int -> CgLoc
mkLocArg (NonVoid id) n
  | argFt /= ft = LocMask ft locLocal
  | otherwise   = locLocal
  where rep       = idPrimRep id
        isClosure = isGcPtrRep rep
        argFt     = argRepFt $ toArgRep rep
        ft        = primRepFieldType rep
        locLocal  = mkLocLocal isClosure argFt n
        maybeConv
          | argFt /= ft = gconv argFt ft
          | otherwise   = mempty

mkRepLocDirect :: (PrimRep, Code) -> CgLoc
mkRepLocDirect (rep, code) = LocDirect isClosure ft code
  where isClosure = isGcPtrRep rep
        ft = expectJust "mkRepLocDirect" $ primRepFieldType_maybe rep

locArgRep :: CgLoc -> ArgRep
locArgRep loc = case loc of
  LocLocal isClosure ft _ -> locRep isClosure ft
  LocStatic {} -> P
  LocField isClosure ft _ _ -> locRep isClosure ft
  LocDirect isClosure ft _ -> locRep isClosure ft
  LocMask ft _ -> locRep (ft == closureType) ft
  LocLne {} -> panic "logArgRep: Cannot pass a let-no-escape binding!"
  where locRep isClosure ft = if isClosure then P else ftArgRep ft

locFt :: CgLoc -> FieldType
locFt (LocLocal _ ft _) = ft
locFt (LocStatic ft _ _) = ft
locFt (LocField _ ft _ _) = ft
locFt (LocDirect _ ft _) = ft
locFt (LocMask ft _) = ft
locFt loc = pprPanic "locFt" $ ppr loc

storeLoc :: CgLoc -> Code -> Code
storeLoc (LocLocal _ ft n) code = code <> gstore ft n
storeLoc (LocMask _ loc) code = storeLoc loc code
storeLoc loc _ = pprPanic "storeLoc" $ ppr loc

storeDefault :: CgLoc -> Code
storeDefault cgLoc = storeLoc cgLoc $ defaultValue (locFt cgLoc)

loadLoc :: CgLoc -> Code
loadLoc (LocLocal _ ft n) = gload ft n
loadLoc (LocMask ft loc) = loadLoc loc <> gconv (locFt loc) ft
loadLoc (LocStatic ft modClass clName) =
  invokestatic $ mkMethodRef modClass (closure clName) [] (Just ft)
loadLoc (LocField _ ft clClass fieldName) =
     gload (obj clClass) 0
  <> getfield (mkFieldRef clClass fieldName ft)
loadLoc (LocDirect _ _ code) = code
loadLoc loc = pprPanic "loadLoc" $ ppr loc

type CgBindings = IdEnv CgIdInfo

data CgIdInfo =
  CgIdInfo { cgId         :: Id,
             cgLambdaForm :: LambdaFormInfo,
             cgLocation   :: CgLoc }

instance Outputable CgIdInfo where
  ppr CgIdInfo {..} = ppr cgId <+> str "-->" <+> ppr cgLocation

splitStaticLoc :: CgLoc -> (Text, Text)
splitStaticLoc (LocStatic _ modClass clName) = (modClass, clName)
splitStaticLoc loc = pprPanic "splitStaticLoc" $ ppr loc

getJavaInfo :: DynFlags -> CgIdInfo -> (Text, Text, Text)
getJavaInfo dflags CgIdInfo { cgLocation, cgLambdaForm }
  = (modClass, clName, clClass)
  where (modClass, clName) = splitStaticLoc cgLocation
        -- TODO: Reduce duplication
        clClass = fromMaybe (qualifiedName modClass clName)
                            $ maybeDataConClass dflags cgLambdaForm

maybeDataConClass :: DynFlags -> LambdaFormInfo -> Maybe Text
maybeDataConClass dflags (LFCon dataCon) = Just $ dataConClass dflags dataCon
maybeDataConClass _ _ = Nothing

mkCgIdInfo :: DynFlags -> Id -> LambdaFormInfo -> CgIdInfo
mkCgIdInfo dflags id lfInfo =
  CgIdInfo { cgId = id
           , cgLambdaForm = lfInfo
           , cgLocation = loc }
  where loc = mkStaticLoc dflags id lfInfo

mkCgIdInfoWithLoc :: Id -> LambdaFormInfo -> CgLoc -> CgIdInfo
mkCgIdInfoWithLoc id lfInfo cgLoc =
  CgIdInfo { cgId = id
           , cgLambdaForm = lfInfo
           , cgLocation = cgLoc }

mkStaticLoc :: DynFlags -> Id -> LambdaFormInfo -> CgLoc
mkStaticLoc dflags id _ = LocStatic closureType modClass clName
  where name = idName id
        mod = fromMaybe (error "mkStaticLoc: No module")
            $ nameModule_maybe name
        clName = nameText dflags True name
        modClass = moduleJavaClass mod
        -- clClass
        --   | Just c <- maybeDataConClass lfInfo = c
        --   | Just c <- maybeTyConClass (idType id) = c
        --   | otherwise = qualifiedName modClass clName

-- maybeTyConClass :: Type -> Maybe Text
-- maybeTyConClass ty = case repType ty of
--   UnaryRep (TyConApp tc _) -> Just $ tyConClass tc
--   _ -> Nothing

data StandardFormInfo
  = NonStandardThunk
        -- The usual case: not of the standard forms

  | SelectorThunk
        -- A SelectorThunk is of form
        --      case x of
        --           con a1,..,an -> ak
        -- and the constructor is from a single-constr type.
      Int -- Field position
      ArgRep -- Field type
        --WordOff         -- 0-origin offset of ak within the "goods" of
                        -- constructor (Recall that the a1,...,an may be laid
                        -- out in the heap in a non-obvious order.)

  | ApThunk
        -- An ApThunk is of form
        --        x1 ... xn
        -- The code for the thunk just pushes x2..xn on the stack and enters x1.
        -- There are a few of these (for 1 <= n <= MAX_SPEC_AP_SIZE) pre-compiled
        -- in the RTS to save space.
        RepArity                -- Arity, n

type CallPattern = (RepArity, [FieldType])

data ArgFVDescr = ArgFVSpec (Maybe CallPattern)

data LambdaFormInfo
  = LFReEntrant {
      lfTopLevelFlag :: TopLevelFlag,
      lfArity :: !RepArity,
      lfNoFreeVars :: !Bool,
      lfArgDescriptor :: ArgFVDescr }

  | LFThunk {
      lfTopLevelFlag :: TopLevelFlag,
      lfNoFreeVars :: !Bool,
      lfUpdatable :: !Bool,
      lfStandardFormInfo :: StandardFormInfo,
      lfMaybeFunction :: !Bool }

  | LFCon { lfDataCon :: DataCon }

  | LFUnknown { lfMaybeFunction :: !Bool }

  | LFUnLifted          -- A value of unboxed type;
                        -- always a value, needs evaluation

  | LFLetNoEscape       -- See LetNoEscape module for precise description

lfFieldType :: LambdaFormInfo -> FieldType
lfFieldType LFReEntrant {} = funType
lfFieldType LFThunk {} = thunkType
lfFieldType LFCon {} = conType
lfFieldType _ = closureType

-- isLFSimple :: LambdaFormInfo -> Bool
-- isLFSimple LFUnLifted = True
-- isLFSimple LFUnknown {} = True
-- isLFSimple LFLetNoEscape = True
-- isLFSimple _ = False

isLFThunk :: LambdaFormInfo -> Bool
isLFThunk LFThunk {} = True
isLFThunk _          = False

lfStaticThunk :: LambdaFormInfo -> Bool
lfStaticThunk (LFThunk topLevel _ _ _ _) = isTopLevel topLevel
lfStaticThunk _ = False

-------------------------------------
--        Non-void types
-------------------------------------
-- We frequently need the invariant that an Id or a an argument
-- is of a non-void type. This type is a witness to the invariant.

newtype NonVoid a = NonVoid a
  deriving (Eq, Show)

instance Outputable a => Outputable (NonVoid a) where
  ppr (NonVoid x) = ppr x

-- Use with care; if used inappropriately, it could break invariants.
unsafeStripNV :: NonVoid a -> a
unsafeStripNV (NonVoid a) = a

nonVoidIds :: [Id] -> [NonVoid Id]
nonVoidIds ids = [NonVoid id | id <- ids, not (isVoidRep (idPrimRep id))]

getNonVoids :: [(Maybe FieldType, a)] -> [NonVoid a]
getNonVoids = mapMaybe (\(mft, val) -> case mft of
                           Just _ -> Just (NonVoid val)
                           Nothing -> Nothing)

getNonVoidFts :: [(Maybe FieldType, a)] -> [(FieldType, NonVoid a)]
getNonVoidFts = mapMaybe (\(mft, val) -> case mft of
                           Just ft -> Just (ft, NonVoid val)
                           Nothing -> Nothing)

enterMethod :: CgLoc -> Code
enterMethod cgLoc
  = loadLoc cgLoc
 <> loadContext
 <> invokevirtual (mkMethodRef stgClosure "enter" [contextType] (ret closureType))

evaluateMethod :: CgLoc -> Code
evaluateMethod cgLoc
  = loadLoc cgLoc
 <> loadContext
 <> invokevirtual (mkMethodRef stgClosure "evaluate" [contextType] (ret closureType))

type RecIndexes = [(Int, Id)]
type RecInfo = (Text, Text, Text, FieldRef, Code, RecIndexes)

type FunRecInfo = (Int, FunRecMap)
type FunRecMap  = VarEnv (Int, [FieldType])

instance Outputable FieldType where
  ppr = str . show
