{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- |
--
-- Perform general rule-based simplification based on data dependency
-- information.  This module will:
--
--    * Perform common-subexpression elimination (CSE).
--
--    * Hoist expressions out of loops (including lambdas) and
--    branches.  This is done as aggressively as possible.
--
--    * Apply simplification rules (see
--    "Futhark.EnablingOpts.Simplification").
--
module Futhark.EnablingOpts.Simplifier
  ( simplifyProg
  , simplifyOneLambda
  )
  where

import Control.Applicative
import Control.Monad.Writer
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.RWS

import Data.Graph
import Data.Hashable
import Data.List
import Data.Loc
import Data.Maybe
import qualified Data.HashMap.Strict as HM
import Data.Ord
import qualified Data.HashSet as HS

import Futhark.InternalRep
import Futhark.MonadFreshNames
import Futhark.EnablingOpts.Simplifier.CSE
import qualified Futhark.EnablingOpts.SymbolTable as ST
import Futhark.EnablingOpts.Simplifier.Rules
import Futhark.EnablingOpts.Simplifier.Apply

-- | Simplify the given program.  Even if the output differs from the
-- output, meaningful simplification may not have taken place - the
-- order of bindings may simply have been rearranged.  The function is
-- idempotent, however.
simplifyProg :: Prog -> Prog
simplifyProg prog =
  Prog $ fst $ runSimpleM (mapM simplifyFun $ progFunctions prog)
               (emptyEnv prog) namesrc
  where namesrc = newNameSourceForProg prog

-- | Simplify just a single 'Lambda'.
simplifyOneLambda :: MonadFreshNames m => Prog -> Lambda -> m Lambda
simplifyOneLambda prog lam = do
  let simplifyOneLambda' = blockAllHoisting $
                           bindParams (lambdaParams lam) $
                           simplifyBody $ lambdaBody lam
  body' <- modifyNameSource $ runSimpleM simplifyOneLambda' $ emptyEnv prog
  return $ lam { lambdaBody = body' }

simplifyFun :: FunDec -> SimpleM FunDec
simplifyFun (fname, rettype, params, body, loc) = do
  body' <- blockAllHoisting $ bindParams params $ simplifyBody body
  return (fname, rettype, params, body', loc)

data BindNeed = LoopNeed [(Ident,SubExp)] Ident SubExp Body
              | LetNeed [Ident] Exp [Exp]
                deriving (Show, Eq)

type NeedSet = [BindNeed]

asTail :: BindNeed -> Body
asTail (LoopNeed merge i bound loopbody) =
  Body [DoLoop merge i bound loopbody] $ Result [] [] loc
    where loc = srclocOf loopbody
asTail (LetNeed pat e _) =
  Body [Let pat e] $ Result [] [] loc
    where loc = srclocOf pat

requires :: BindNeed -> HS.HashSet VName
requires (LetNeed pat e alts) =
  freeInE `mappend` freeInPat
  where freeInE   = mconcat $ map freeNamesInExp $ e : alts
        freeInPat = mconcat $ map (freeInType . identType) pat
requires bnd = HS.map identName $ freeInBody $ asTail bnd

provides :: BindNeed -> HS.HashSet VName
provides (LoopNeed merge _ _ _)     = patNameSet $ map fst merge
provides (LetNeed pat _ _)          = patNameSet pat

patNameSet :: [Ident] -> HS.HashSet VName
patNameSet = HS.fromList . map identName

freeInType :: Type -> HS.HashSet VName
freeInType = mconcat . map (freeNamesInExp . subExp) . arrayDims

data Need = Need { needBindings :: NeedSet
                 , freeInBound  :: HS.HashSet VName
                 }

instance Monoid Need where
  Need b1 f1 `mappend` Need b2 f2 = Need (b1 <> b2) (f1 <> f2)
  mempty = Need [] HS.empty

data Env = Env { envDupeState :: DupeState
               , envVtable  :: ST.SymbolTable
               , envProgram   :: Prog
               }

emptyEnv :: Prog -> Env
emptyEnv prog = Env {
                  envDupeState = newDupeState
                , envVtable = ST.empty
                , envProgram = prog
                }

newtype SimpleM a = SimpleM (RWS
                           Env                -- Reader
                           Need               -- Writer
                           (NameSource VName) -- State
                           a)
  deriving (Applicative, Functor, Monad,
            MonadWriter Need, MonadReader Env, MonadState (NameSource VName))

instance MonadFreshNames SimpleM where
  getNameSource = get
  putNameSource = put

runSimpleM :: SimpleM a -> Env -> VNameSource -> (a, VNameSource)
runSimpleM (SimpleM m) env src = let (x, src', _) = runRWS m env src
                                 in (x, src')

needThis :: BindNeed -> SimpleM ()
needThis need = tell $ Need [need] HS.empty

boundFree :: HS.HashSet VName -> SimpleM ()
boundFree fs = tell $ Need [] fs

usedName :: VName -> SimpleM ()
usedName = boundFree . HS.singleton

collectFreeOccurences :: SimpleM a -> SimpleM (a, HS.HashSet VName)
collectFreeOccurences m = pass $ do
  (x, needs) <- listen m
  return ((x, freeInBound needs),
          const needs { freeInBound  = HS.empty })

localVtable :: (ST.SymbolTable -> ST.SymbolTable) -> SimpleM a -> SimpleM a
localVtable f = local $ \env -> env { envVtable = f $ envVtable env }

binding :: [(VName, Exp)] -> SimpleM a -> SimpleM a
binding = localVtable . flip (foldr $ uncurry ST.insert)

bindParams :: [Param] -> SimpleM a -> SimpleM a
bindParams params =
  localVtable $ \vtable ->
    let vtable' = foldr (ST.insert' . identName) vtable params
    in foldr (`ST.isAtLeast` 0) vtable' sizevars
  where sizevars = mapMaybe isVar $ concatMap (arrayDims . identType) params
        isVar (Var v) = Just $ identName v
        isVar _       = Nothing

bindLoopVar :: Ident -> SubExp -> SimpleM a -> SimpleM a
bindLoopVar var upper =
  localVtable $ clampUpper . clampVar
  where -- If we enter the loop, then 'var' is at least zero, and at
        -- most 'upper'-1 (so this is not completely tight - FIXME).
        clampVar = ST.insertBounded (identName var) (Just $ intconst 0 $ srclocOf var,
                                                     Just upper)
        -- If we enter the loop, then 'upper' is at least one.
        clampUpper = case upper of Var v -> ST.isAtLeast (identName v) 1
                                   _     -> id

withBinding :: [Ident] -> Exp -> SimpleM a -> SimpleM a
withBinding pat e = withSeveralBindings pat e []

withSeveralBindings :: [Ident] -> Exp -> [Exp]
                    -> SimpleM a -> SimpleM a
withSeveralBindings pat e alts m = do
  ds <- asks envDupeState
  let (e', ds') = performCSE ds pat e
      (es, ds'') = performMultipleCSE ds pat alts
      patbnds = getPropBnds pat e'
  needThis $ LetNeed pat e' es
  binding patbnds $
    local (\env -> env { envDupeState = ds' <> ds''}) m

getPropBnds :: [Ident] -> Exp -> [(VName, Exp)]
getPropBnds [Ident var _ _] e = [(var, e)]
getPropBnds ids (SubExps ts _)
  | length ids == length ts =
    concatMap (\(x,y)-> getPropBnds [x] (subExp y)) $ zip ids ts
getPropBnds _ _ = []

bindLet :: [Ident] -> Exp -> SimpleM a -> SimpleM a

bindLet = withBinding

bindLoop :: [(Ident,SubExp)] -> Ident -> SubExp -> Body -> SimpleM a -> SimpleM a
bindLoop merge i bound body m = do
  needThis $ LoopNeed merge i bound body
  m

addBindings :: MonadFreshNames m =>
               DupeState -> [BindNeed] -> Body -> HS.HashSet VName
            -> m (Body, HS.HashSet VName)
addBindings dupes needs body uses = do
  (uses',bnds) <- simplifyBindings uses $ snd $ mapAccumL pick (HM.empty, dupes) needs
  return (insertBindings bnds body, uses')
  where simplifyBindings uses' = foldM comb (uses',[]) . reverse

        -- Do not actually insert binding if it is not used.
        comb (uses',bnds) (bnd, provs, reqs)
          | provs `intersects` uses' = do
            res <- bottomUpSimplifyBinding uses' bnd
            case res of
              Nothing    -> return ((uses' `HS.difference` provs) `HS.union` reqs,
                                    bnd:bnds)
              Just optimbnds -> do
                (uses'',optimbnds') <-
                  simplifyBindings uses' $ map attachUsage optimbnds
                return (uses'', optimbnds'++bnds)
          | otherwise =
            return (uses', bnds)

        attachUsage bnd = (bnd, providedByBnd bnd, usedInBnd bnd)
        providedByBnd (Let pat _) =
          HS.fromList $ map identName pat
        providedByBnd (DoLoop merge _ _ _) =
          HS.fromList $ map (identName . fst) merge
        usedInBnd bnd = freeNamesInBody $ Body [bnd] $ Result [] [] noLoc

        pick (m,ds) bnd@(LoopNeed merge loopvar boundexp loopbody) =
          ((m `HM.union` distances m bnd, ds),
           (DoLoop merge loopvar boundexp loopbody,
            provides bnd, requires bnd))

        pick (m,ds) (LetNeed pat e alts) =
          let add e' =
                let (e'',ds') = performCSE ds pat e'
                    bnd       = LetNeed pat e'' []
                in ((m `HM.union` distances m bnd, ds'),
                    (Let pat e'',
                     provides bnd, requires bnd))
          in case map snd $ sortBy (comparing fst) $ map (score m) $ e:alts of
               e':_ -> add e'
               _    -> add e

score :: HM.HashMap VName Int -> Exp -> (Int, Exp)
score m (SubExps [Var k] _) =
  (fromMaybe (-1) $ HM.lookup (identName k) m, subExp $ Var k)
score m e =
  (HS.foldl' f 0 $ freeNamesInExp e, e)
  where f x k = case HM.lookup k m of
                  Just y  -> max x y
                  Nothing -> x

expCost :: Exp -> Int
expCost (Map {}) = 1
expCost (Filter {}) = 1
expCost (Reduce {}) = 1
expCost (Scan {}) = 1
expCost (Redomap {}) = 1
expCost (Rearrange {}) = 1
expCost (Copy {}) = 1
expCost (Concat {}) = 1
expCost (Split {}) = 1
expCost (Reshape {}) = 1
expCost (Replicate {}) = 1
expCost _ = 0

distances :: HM.HashMap VName Int -> BindNeed -> HM.HashMap VName Int
distances m need = HM.fromList [ (k, d+cost) | k <- HS.toList outs ]
  where d = HS.foldl' f 0 ins
        (outs, ins, cost) =
          case need of
            LetNeed pat e _ ->
              (patNameSet pat, freeNamesInExp e, expCost e)
            LoopNeed merge _ bound loopbody ->
              (patNameSet $ map fst merge,
               mconcat $ freeNamesInBody loopbody : map freeNamesInExp
               (subExp bound : map (subExp . snd) merge),
               1)
        f x k = case HM.lookup k m of
                  Just y  -> max x y
                  Nothing -> x

inDepOrder :: [BindNeed] -> [BindNeed]
inDepOrder = flattenSCCs . stronglyConnComp . buildGraph
  where buildGraph bnds =
          [ (bnd, representative $ provides bnd, deps) |
            bnd <- bnds,
            let deps = [ representative $ provides dep
                         | dep <- bnds, dep `mustPrecede` bnd ] ]

        -- As all names are unique, a pattern can be uniquely
        -- represented by any of its names.  If the pattern has no
        -- names, then it doesn't matter anyway.
        representative s = case HS.toList s of
                             x:_ -> Just x
                             []  -> Nothing

mustPrecede :: BindNeed -> BindNeed -> Bool
bnd1 `mustPrecede` bnd2 =
  not $ HS.null $ (provides bnd1 `HS.intersection` requires bnd2) `HS.union`
                  (consumedInBody e2 `HS.intersection` requires bnd1)
  where e2 = asTail bnd2

anyIsFreeIn :: HS.HashSet VName -> Exp -> Bool
anyIsFreeIn ks = (ks `intersects`) . HS.map identName . freeInExp

intersects :: (Eq a, Hashable a) => HS.HashSet a -> HS.HashSet a -> Bool
intersects a b = not $ HS.null $ a `HS.intersection` b

data BodyInfo = BodyInfo { bodyConsumes :: HS.HashSet VName
                         }

bodyInfo :: Body -> BodyInfo
bodyInfo b = BodyInfo {
               bodyConsumes = consumedInBody b
             }

type BlockPred = BodyInfo -> BindNeed -> Bool

orIf :: BlockPred -> BlockPred -> BlockPred
orIf p1 p2 body need = p1 body need || p2 body need

splitHoistable :: BlockPred -> Body -> NeedSet -> ([BindNeed], NeedSet)
splitHoistable block body needs =
  let (blocked, hoistable, _) =
        foldl split ([], [], HS.empty) $ inDepOrder needs
  in (reverse blocked, hoistable)
  where block' = block $ bodyInfo body
        split (blocked, hoistable, ks) need =
          case need of
            LetNeed pat e es ->
              let bad e' = block' (LetNeed pat e' []) || ks `anyIsFreeIn` e'
              in case (bad e, filter (not . bad) es) of
                   (True, [])     ->
                     (need : blocked, hoistable,
                      patNameSet pat `HS.union` ks)
                   (True, e':es') ->
                     (blocked, LetNeed pat e' es' : hoistable, ks)
                   (False, es')   ->
                     (blocked, LetNeed pat e es' : hoistable, ks)
            _ | requires need `intersects` ks || block' need ->
                (need : blocked, hoistable, provides need `HS.union` ks)
              | otherwise ->
                (blocked, need : hoistable, ks)

blockIfSeq :: [BlockPred] -> SimpleM Body -> SimpleM Body
blockIfSeq ps m = foldl (flip blockIf) m ps

blockIf :: BlockPred -> SimpleM Body -> SimpleM Body
blockIf block m = pass $ do
  (body, needs) <- listen m
  ds <- asks envDupeState
  let (blocked, hoistable) = splitHoistable block body $ needBindings needs
  (e, fs) <- addBindings ds blocked body $ freeInBound needs
  return (e,
          const Need { needBindings = hoistable
                     , freeInBound  = fs
                     })

blockAllHoisting :: SimpleM Body -> SimpleM Body
blockAllHoisting = blockIf $ \_ _ -> True

hasFree :: HS.HashSet VName -> BlockPred
hasFree ks _ need = ks `intersects` requires need

isNotSafe :: BlockPred
isNotSafe _ = not . safeBnd
  where safeBnd (LetNeed _ e _) = safeExp e
        safeBnd _               = False

isNotCheap :: BlockPred
isNotCheap _ = not . cheapBnd
  where cheap (BinOp {})   = True
        cheap (SubExps {}) = True
        cheap (Not {})     = True
        cheap (Negate {})  = True
        cheap _            = False
        cheapBnd (LetNeed _ e _) = cheap e
        cheapBnd _               = False

uniqPat :: [Ident] -> Bool
uniqPat = any $ unique . identType

isUniqueBinding :: BlockPred
isUniqueBinding _ (LoopNeed merge _ _ _)     = uniqPat $ map fst merge
isUniqueBinding _ (LetNeed pat _ _)          = uniqPat pat

isConsumed :: BlockPred
isConsumed body need =
  provides need `intersects` bodyConsumes body

hoistCommon :: SimpleM Body -> SimpleM Body -> SimpleM (Body, Body)
hoistCommon m1 m2 = pass $ do
  (body1, needs1) <- listen m1
  (body2, needs2) <- listen m2
  let splitOK = splitHoistable $ isNotSafe `orIf` isNotCheap
      (needs1', safe1) = splitOK body1 $ needBindings needs1
      (needs2', safe2) = splitOK body2 $ needBindings needs2
  (e1, f1) <- addBindings newDupeState needs1' body1 $ freeInBound needs1
  (e2, f2) <- addBindings newDupeState needs2' body2 $ freeInBound needs2
  return ((e1, e2),
          const Need { needBindings = safe1 <> safe2
                     , freeInBound = f1 <> f2
                     })

simplifyBody :: Body -> SimpleM Body

simplifyBody (Body [] (Result cs es loc)) =
  resultBody <$> simplifyCerts cs <*>
                 mapM simplifySubExp es <*> pure loc

simplifyBody (Body (Let pat e:bnds) res) = do
  pat' <- mapM simplifyIdentBinding pat
  e' <- simplifyExp e
  vtable <- asks envVtable
  simplified <- topDownSimplifyBinding vtable (Let pat e')
  case simplified of
    Just newbnds ->
      simplifyBody $ Body (newbnds++bnds) res
    Nothing      ->
      bindLet pat' e' $ simplifyBody $ Body bnds res

simplifyBody (Body (DoLoop merge loopvar boundexp loopbody:bnds) res) = do
  let (mergepat, mergeexp) = unzip merge
  mergepat' <- mapM simplifyIdentBinding mergepat
  mergeexp' <- mapM simplifySubExp mergeexp
  boundexp' <- simplifySubExp boundexp
  -- XXX our loop representation is retarded (see collectFreeOccurences).
  (loopbody', _) <- collectFreeOccurences $
                    blockIfSeq [hasFree boundnames, isConsumed] $
                    bindLoopVar loopvar boundexp' $
                    simplifyBody loopbody
  let merge' = zip mergepat' mergeexp'
  vtable <- asks envVtable
  simplified <- topDownSimplifyBinding vtable $
                DoLoop merge' loopvar boundexp' loopbody'
  case simplified of
    Nothing -> bindLoop merge' loopvar boundexp' loopbody' $
               simplifyBody $ Body bnds res
    Just newbnds -> simplifyBody $ Body (newbnds++bnds) res
  where boundnames = identName loopvar `HS.insert` patNameSet (map fst merge)

simplifyExp :: Exp -> SimpleM Exp

simplifyExp (If cond tbranch fbranch t loc) = do
  -- Here, we have to check whether 'cond' puts a bound on some free
  -- variable, and if so, chomp it.  We also try to do CSE across
  -- branches.
  cond' <- simplifySubExp cond
  let simplifyT = localVtable (ST.updateBounds True cond) $
                  simplifyBody tbranch
      simplifyF = localVtable (ST.updateBounds False cond) $
                  simplifyBody fbranch
  (tbranch',fbranch') <- hoistCommon simplifyT simplifyF
  t' <- mapM simplifyType t
  return $ If cond' tbranch' fbranch' t' loc

-- The simplification rules cannot handle Apply, because it requires
-- access to the full program.
simplifyExp (Apply fname args tp loc) = do
  args' <- mapM (simplifySubExp . fst) args
  tp' <- mapM simplifyType tp
  prog <- asks envProgram
  vtable <- asks envVtable
  case simplifyApply prog vtable fname args loc of
    Just e  -> return e
    Nothing -> return $ Apply fname (zip args' $ map snd args) tp' loc

simplifyExp e = simplifyExpBase e

simplifyExpBase :: Exp -> SimpleM Exp
simplifyExpBase = mapExpM hoist
  where hoist = Mapper {
                  mapOnExp = simplifyExp
                , mapOnBody = simplifyBody
                , mapOnSubExp = simplifySubExp
                , mapOnLambda = simplifyLambda
                , mapOnIdent = simplifyIdent
                , mapOnType = simplifyType
                , mapOnValue = return
                , mapOnCertificates = simplifyCerts
                }

simplifySubExp :: SubExp -> SimpleM SubExp
simplifySubExp (Var ident@(Ident vnm _ pos)) = do
  bnd <- asks $ ST.lookup vnm . envVtable
  case bnd of
    Just (ST.Value v)
      | isBasicTypeVal v  -> return $ Constant v pos
    Just (ST.VarId  id' tp1) -> do usedName id'
                                   return $ Var $ Ident id' tp1 pos
    Just (ST.SymExp (SubExps [se] _)) -> return se
    _                                 -> Var <$> simplifyIdent ident
  where isBasicTypeVal = basicType . valueType
simplifySubExp (Constant v loc) = return $ Constant v loc

simplifyIdentBinding :: Ident -> SimpleM Ident
simplifyIdentBinding v = do
  t' <- simplifyType $ identType v
  return v { identType = t' }

simplifyIdent :: Ident -> SimpleM Ident
simplifyIdent v = do
  usedName $ identName v
  t' <- simplifyType $ identType v
  return v { identType = t' }

simplifyType :: TypeBase als Shape -> SimpleM (TypeBase als Shape)
simplifyType t = do dims <- mapM simplifySubExp $ arrayDims t
                    return $ t `setArrayShape` Shape dims

simplifyLambda :: Lambda -> SimpleM Lambda
simplifyLambda (Lambda params body rettype loc) = do
  body' <- blockIf (hasFree params' `orIf` isUniqueBinding) $ simplifyBody body
  rettype' <- mapM simplifyType rettype
  return $ Lambda params body' rettype' loc
  where params' = patNameSet $ map fromParam params

simplifyCerts :: Certificates -> SimpleM Certificates
simplifyCerts = liftM (nub . concat) . mapM check
  where check idd = do
          vv <- asks $ ST.lookup (identName idd) . envVtable
          case vv of
            Just (ST.Value (BasicVal Checked)) -> return []
            Just (ST.VarId  id' tp1) -> do usedName id'
                                           return [Ident id' tp1 loc]
            _ -> do usedName $ identName idd
                    return [idd]
          where loc = srclocOf idd
