{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

-- | Alias analysis of a full Futhark program.  Takes as input a
-- program with an arbitrary rep and produces one with aliases.  This
-- module does not implement the aliasing logic itself, and derives
-- its information from definitions in
-- "Futhark.IR.Prop.Aliases" and
-- "Futhark.IR.Aliases".  The alias information computed
-- here will include transitive aliases (note that this is not what
-- the building blocks do).
module Futhark.Analysis.Alias
  ( aliasAnalysis,

    -- * Ad-hoc utilities
    analyseFun,
    analyseStms,
    analyseExp,
    analyseBody,
    analyseLambda,
  )
where

import Data.List (foldl')
import qualified Data.Map as M
import Futhark.IR.Aliases

-- | Perform alias analysis on a Futhark program.
aliasAnalysis ::
  (ASTRep rep, CanBeAliased (Op rep)) =>
  Prog rep ->
  Prog (Aliases rep)
aliasAnalysis prog =
  prog
    { progConsts = fst (analyseStms mempty (progConsts prog)),
      progFuns = map analyseFun (progFuns prog)
    }

-- | Perform alias analysis on function.
analyseFun ::
  (ASTRep rep, CanBeAliased (Op rep)) =>
  FunDef rep ->
  FunDef (Aliases rep)
analyseFun (FunDef entry attrs fname restype params body) =
  FunDef entry attrs fname restype params body'
  where
    body' = analyseBody mempty body

-- | Perform alias analysis on Body.
analyseBody ::
  ( ASTRep rep,
    CanBeAliased (Op rep)
  ) =>
  AliasTable ->
  Body rep ->
  Body (Aliases rep)
analyseBody atable (Body rep stms result) =
  let (stms', _atable') = analyseStms atable stms
   in mkAliasedBody rep stms' result

-- | Perform alias analysis on statements.
analyseStms ::
  (ASTRep rep, CanBeAliased (Op rep)) =>
  AliasTable ->
  Stms rep ->
  (Stms (Aliases rep), AliasesAndConsumed)
analyseStms orig_aliases =
  foldl' f (mempty, (orig_aliases, mempty)) . stmsToList
  where
    f (stms, aliases) stm =
      let stm' = analyseStm (fst aliases) stm
          atable' = trackAliases aliases stm'
       in (stms <> oneStm stm', atable')

analyseStm ::
  (ASTRep rep, CanBeAliased (Op rep)) =>
  AliasTable ->
  Stm rep ->
  Stm (Aliases rep)
analyseStm aliases (Let pat (StmAux cs attrs dec) e) =
  let e' = analyseExp aliases e
      pat' = mkAliasedPat pat e'
      rep' = (AliasDec $ consumedInExp e', dec)
   in Let pat' (StmAux cs attrs rep') e'

-- | Perform alias analysis on expression.
analyseExp ::
  (ASTRep rep, CanBeAliased (Op rep)) =>
  AliasTable ->
  Exp rep ->
  Exp (Aliases rep)
-- Would be better to put this in a BranchType annotation, but that
-- requires a lot of other work.
analyseExp aliases (Match cond cases defbody matchdec) =
  let cases' = map (fmap $ analyseBody aliases) cases
      defbody' = analyseBody aliases defbody
      all_cons = foldMap (snd . fst . bodyDec) $ defbody' : map caseBody cases'
      isConsumed v =
        any (`nameIn` unAliases all_cons) $
          v : namesToList (M.findWithDefault mempty v aliases)
      notConsumed =
        AliasDec
          . namesFromList
          . filter (not . isConsumed)
          . namesToList
          . unAliases
      onBody (Body ((als, cons), dec) stms res) =
        Body ((map notConsumed als, cons), dec) stms res
      cases'' = map (fmap onBody) cases'
      defbody'' = onBody defbody'
   in Match cond cases'' defbody'' matchdec
analyseExp aliases e = mapExp analyse e
  where
    analyse =
      Mapper
        { mapOnSubExp = pure,
          mapOnVName = pure,
          mapOnBody = const $ pure . analyseBody aliases,
          mapOnRetType = pure,
          mapOnBranchType = pure,
          mapOnFParam = pure,
          mapOnLParam = pure,
          mapOnOp = pure . addOpAliases aliases
        }

-- | Perform alias analysis on lambda.
analyseLambda ::
  (ASTRep rep, CanBeAliased (Op rep)) =>
  AliasTable ->
  Lambda rep ->
  Lambda (Aliases rep)
analyseLambda aliases lam =
  let body = analyseBody aliases $ lambdaBody lam
   in lam
        { lambdaBody = body,
          lambdaParams = lambdaParams lam
        }
