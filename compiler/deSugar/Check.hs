
{-
  Author: George Karachalias <george.karachalias@cs.kuleuven.be>
-}

{-# OPTIONS_GHC -Wwarn #-}   -- unused variables

{-# LANGUAGE CPP #-}

module Check ( checkpm, PmResult, pprUncovered, toTcTypeBag ) where

#include "HsVersions.h"

import HsSyn
import TcHsSyn
import DsUtils
import MatchLit
import Id
import ConLike
import DataCon
import Name
import TysWiredIn
import TyCon
import SrcLoc
import Util
import BasicTypes
import Outputable
import FastString

-- For the new checker (We need to remove and reorder things)
import DsMonad ( DsM, initTcDsForSolver, getDictsDs, addDictsDs, getSrcSpanDs)
import TcSimplify( tcCheckSatisfiability )
import UniqSupply (MonadUnique(..))
import TcType ( TcType, mkTcEqPred, vanillaSkolemTv, TcTyVar )
import Var ( EvVar, varType, tyVarKind, tyVarName, mkTcTyVar, TyVar, isTcTyVar, setTyVarKind, setVarType )
import VarSet
import Type( substTys, substTyVars, substTheta, TvSubst )
import TypeRep ( Type(..) )
import Bag (Bag, unitBag, listToBag, emptyBag, unionBags, mapBag )
import Type (expandTypeSynonyms, mkTyConApp)
import ErrUtils
import TcMType (genInstSkolTyVars)
import IOEnv (tryM, failM, anyM)
import Type (tyVarsOfType, substTy, tyVarsOfTypes, closeOverKinds, varSetElemsKvsFirst)

import Control.Monad ( forM, foldM, filterM )
import Control.Applicative (Applicative(..), (<$>))

{-
This module checks pattern matches for:
\begin{enumerate}
  \item Equations that are totally redundant (can be removed from the match)
  \item Exhaustiveness, and returns the equations that are not covered by the match
  \item Equations that are completely overlapped by other equations yet force the
        evaluation of some arguments (but have inaccessible right hand side).
\end{enumerate}

The algorithm used is described in the following paper:
  NO PAPER YET!

%************************************************************************
%*                                                                      *
\subsection{Pattern Match Check Types}
%*                                                                      *
%************************************************************************
-}

-- | Guard representation for the pattern match check. Just represented as a
-- CanItFail for now but can be extended to carry more useful information
type PmGuard = CanItFail

-- | Literal patterns for the pattern match check. Almost identical to LitPat
-- and NPat data constructors of type (Pat id) in file hsSyn/HsPat.lhs
data PmLit id = PmLit HsLit
              | PmOLit (HsOverLit id) (Maybe (SyntaxExpr id)) (SyntaxExpr id)

instance Eq (PmLit id) where
  PmLit  l1            == PmLit  l2            = l1 == l2
  PmOLit l1 Nothing  _ == PmOLit l2 Nothing  _ = l1 == l2
  PmOLit l1 (Just _) _ == PmOLit l2 (Just _) _ = l1 == l2
  _                    == _                    = False

-- | The main pattern type for pattern match check. Only guards, variables,
-- constructors, literals and negative literals. It it sufficient to represent
-- all different patterns, apart maybe from bang and lazy patterns.

-- SPJ... Say that this the term-level stuff only.
-- Drop all types, existential type variables
-- 
data PmPat id = PmGuardPat PmGuard -- Note [Translation to PmPat]
              | PmVarPat { pm_ty :: Type, pm_var :: id }
              | PmConPat { pm_ty :: Type, pm_pat_con :: DataCon, pm_pat_args :: [PmPat id] }
              | PmLitPat { pm_ty :: Type, pm_lit :: PmLit id }
              | PmLitCon { pm_ty :: Type, pm_var :: id, pm_not_lit :: [PmLit id] } -- Note [Negative patterns]

-- | Delta contains all constraints that accompany a pattern vector, including
-- both term-level constraints (guards) and type-lever constraints (EvVars,
-- introduced by GADTs)
data Delta = Delta { delta_evvars :: Bag EvVar -- Type constraints
                   , delta_guards :: PmGuard } -- Term constraints

-- | The result of translation of EquationInfo. The length of the vector may not
-- match the number of the arguments of the match, because guard patterns are
-- interleaved with argument patterns. Note [Translation to PmPat]
type InVec = [PmPat Id] -- NB: No PmLitCon patterns here

type CoveredVec   = (Delta, [PmPat Id]) -- NB: No guards in the vector, all accumulated in delta
type UncoveredVec = (Delta, [PmPat Id]) -- NB: No guards in the vector, all accumulated in delta

-- | A pattern vector may either force or not the evaluation of an argument.
-- Instead of keeping track of which arguments and under which conditions (like
-- we do in the paper), we simply keep track of if it forces anything or not
-- (That is the only thing that we care about anyway)
data Forces = Forces | DoesntForce
  deriving (Eq)

-- | Information about a clause.
data PmTriple = PmTriple { pmt_covered   :: [CoveredVec]   -- cases it covers
                         , pmt_uncovered :: [UncoveredVec] -- what remains uncovered
                         , pmt_forces    :: Forces } -- Whether it forces anything

-- | The result of pattern match check. A tuple containing:
--   * Clauses that are redundant (do not cover anything, do not force anything)
--   * Clauses with inaccessible rhs (do not cover anything, yet force something)
--   * Uncovered cases (in PmPat form)
type PmResult = ([EquationInfo], [EquationInfo], [UncoveredVec])

{-
%************************************************************************
%*                                                                      *
\subsection{Transform EquationInfos to InVecs}
%*                                                                      *
%************************************************************************

Note [Translation to PmPat]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The main translation of @Pat Id@ to @PmPat Id@ is performed by @mViewPat@.

Note that it doesn't return a @PmPat Id@ but @[PmPat Id]@ instead. This happens
because some patterns may introduce a guard in the middle of the vector. For example:

\begin{itemize}
  \item View patterns. Pattern @g -> pat@ must be translated to @[x, pat <- g x]@
        where x is a fresh variable
  \item n+k patterns. Pattern @n+k@ must be translated to @[n', n'>=k, let n = n'-k]@
        where @n'@ is a fresh variable
  \item We do something similar with overloaded lists and pattern synonyms since we
        do not know how to handle them yet. They are both translated into a fresh
        variable and a guard that can fail, but doesn't carry any more information
        with it
\end{itemize}

Note [Negative patterns]
~~~~~~~~~~~~~~~~~~~~~~~~
For the repsesentation of literal patterns we use constructors @PmLitPat@ and
@PmLitCon@ (constrained literal pattern). Note that from translating @Pat Id@
we never get a @PmLitCon@. It can appear only in @CoveredVec@ and @UncoveredVec@.
We generate @PmLitCon@s in cases like the following:
\begin{verbatim}
f :: Int -> Int
f 5 = 1
\end{verbatim}

Where we generate an uncovered vector of the form @PmLitCon Int x [5]@ which can
be read as ``all literals @x@ of type @Int@, apart from @5@''.
-}

-- | Transform EquationInfo to a list of PmPats.
preprocess_match :: EquationInfo -> PmM [PmPat Id]
preprocess_match (EqnInfo { eqn_pats = ps, eqn_rhs = mr }) =
  mapM mViewPat ps >>= return . foldr (++) [preprocessMR mr]
  where
    preprocessMR :: MatchResult -> PmPat Id
    preprocessMR (MatchResult can_fail _) = PmGuardPat can_fail

-- | Transform a Pat Id into a list of PmPat Id -- Note [Translation to PmPat]
mViewPat :: Pat Id -> PmM [PmPat Id]
mViewPat pat@(WildPat _) = pure <$> varFromPat pat
mViewPat pat@(VarPat id) = return [PmVarPat (patTypeExpanded pat) id]
mViewPat (ParPat p)      = mViewPat (unLoc p)
mViewPat (LazyPat p)     = mViewPat (unLoc p) -- NOT SURE. IT IS MORE LAZY THAN THAT. USE A FRESH VARIABLE
-- WAS: mViewPat pat@(LazyPat _) = pure <$> varFromPat pat
mViewPat (BangPat p)     = mViewPat (unLoc p)
mViewPat (AsPat _ p)     = mViewPat (unLoc p)
mViewPat (SigPatOut p _) = mViewPat (unLoc p)
mViewPat (CoPat   _ p _) = mViewPat p

-- Unhandled cases. See Note [Translation to PmPat]
mViewPat pat@(NPlusKPat _ _ _ _)                         = unhandled_case pat
mViewPat pat@(ViewPat _ _ _)                             = unhandled_case pat
mViewPat pat@(ListPat _ _ (Just (_,_)))                  = unhandled_case pat
mViewPat pat@(ConPatOut { pat_con = L _ (PatSynCon _) }) = unhandled_case pat

mViewPat pat@(ConPatOut { pat_con = L _ (RealDataCon con), pat_args = ps }) = do
  args <- mViewConArgs con ps
  return [mkPmConPat (patTypeExpanded pat) con args]

mViewPat pat@(NPat lit mb_neg eq) =
  case pmTidyNPat lit mb_neg eq of -- Note [Tidying literals for pattern matching] in MatchLit.lhs
    NPat lit mb_neg eq ->
      return [PmLitPat (patTypeExpanded pat) (PmOLit lit mb_neg eq)]
    pat -> mViewPat pat -- it was translated to sth else (simple literal or constructor)
  -- Make sure we get back the right type

mViewPat pat@(LitPat lit) =
  case pmTidyLitPat lit of -- Note [Tidying literals for pattern matching] in MatchLit.lhs
    LitPat lit -> do
      return [PmLitPat (patTypeExpanded pat) (PmLit lit)]
    pat -> mViewPat pat -- it was translated to sth else (constructor)
  -- Make sure we get back the right type

mViewPat pat@(ListPat ps _ Nothing) = do
  tidy_ps <- mapM (mViewPat . unLoc) ps
  let mkListPat x y = [mkPmConPat (patTypeExpanded pat) consDataCon (x++y)]
  return $ foldr mkListPat [mkPmConPat (patTypeExpanded pat) nilDataCon []] tidy_ps

-- fake parallel array constructors so that we can handle them
-- like we do with normal constructors
mViewPat pat@(PArrPat ps _) = do
  tidy_ps <- mapM (mViewPat . unLoc) ps
  let fake_con = parrFakeCon (length ps)
  return [mkPmConPat (patTypeExpanded pat) fake_con (concat tidy_ps)]

mViewPat pat@(TuplePat ps boxity _) = do
  tidy_ps <- mapM (mViewPat . unLoc) ps
  let tuple_con = tupleCon (boxityNormalTupleSort boxity) (length ps)
  return [mkPmConPat (patTypeExpanded pat) tuple_con (concat tidy_ps)]

mViewPat (ConPatIn {})      = panic "Check.mViewPat: ConPatIn"
mViewPat (SplicePat {})     = panic "Check.mViewPat: SplicePat"
mViewPat (QuasiQuotePat {}) = panic "Check.mViewPat: QuasiQuotePat"
mViewPat (SigPatIn {})      = panic "Check.mViewPat: SigPatIn"

{-
%************************************************************************
%*                                                                      *
\subsection{Smart Constructors etc.}
%*                                                                      *
%************************************************************************
-}

guardFails :: PmGuard
guardFails = CanFail

guardDoesntFail :: PmGuard
guardDoesntFail = CantFail

guardFailsPat :: PmPat Id
guardFailsPat = PmGuardPat guardFails

freshPmVar :: Type -> PmM (PmPat Id)
freshPmVar ty = do
  unique <- getUniqueM
  let occname = mkVarOccFS (fsLit (show unique))        -- we use the unique as the name (unsafe because
      name    = mkInternalName unique occname noSrcSpan -- we expose it. we need something more elegant
      idname  = mkLocalId name ty
  return (PmVarPat ty idname)

mkPmConPat :: Type -> DataCon -> [PmPat id] -> PmPat id
mkPmConPat ty con pats = PmConPat { pm_ty = ty, pm_pat_con = con, pm_pat_args = pats }

empty_triple :: PmTriple
empty_triple = PmTriple [] [] DoesntForce

empty_delta :: Delta
empty_delta = Delta emptyBag guardDoesntFail

newEqPmM :: Type -> Type -> PmM EvVar
newEqPmM ty1 ty2 = do
  unique <- getUniqueM
  let name = mkSystemName unique (mkVarOccFS (fsLit "pmcobox"))
  return $ newEvVar name (mkTcEqPred ty1 ty2)

nameType :: String -> Type -> PmM EvVar
nameType name ty = do
  unique <- getUniqueM
  let occname = mkVarOccFS (fsLit (name++"_"++show unique))
  return $ newEvVar (mkInternalName unique occname noSrcSpan) ty

newEvVar :: Name -> Type -> EvVar
newEvVar name ty = mkLocalId name (toTcType ty)

toTcType :: Type -> TcType
toTcType ty = to_tc_type emptyVarSet ty
   where
    to_tc_type :: VarSet -> Type -> TcType
    -- The constraint solver expects EvVars to have TcType, in which the
    -- free type variables are TcTyVars. So we convert from Type to TcType here
    -- A bit tiresome; but one day I expect the two types to be entirely separate
    -- in which case we'll definitely need to do this
    to_tc_type forall_tvs (TyVarTy tv)
      | Just var <- lookupVarSet forall_tvs tv = TyVarTy var
      | otherwise = TyVarTy (toTcTyVar tv)
    to_tc_type  ftvs (FunTy t1 t2)     = FunTy (to_tc_type ftvs t1) (to_tc_type ftvs t2)
    to_tc_type  ftvs (AppTy t1 t2)     = AppTy (to_tc_type ftvs t1) (to_tc_type ftvs t2)
    to_tc_type  ftvs (TyConApp tc tys) = TyConApp tc (map (to_tc_type ftvs) tys)
    to_tc_type  ftvs (ForAllTy tv ty)  = let tv' = toTcTyVar tv
                                         in ForAllTy tv' (to_tc_type (ftvs `extendVarSet` tv') ty)
    to_tc_type _ftvs (LitTy l)         = LitTy l

toTcTyVar :: TyVar -> TcTyVar
toTcTyVar tv
  | isTcTyVar tv = setVarType tv (toTcType (tyVarKind tv))
  | isId tv      = pprPanic "toTcTyVar: Id:" (ppr tv)
  | otherwise    = mkTcTyVar (tyVarName tv) (toTcType (tyVarKind tv)) vanillaSkolemTv

toTcTypeBag :: Bag EvVar -> Bag EvVar -- All TyVars are transformed to TcTyVars
toTcTypeBag evvars = mapBag (\tv -> setTyVarKind tv (toTcType (tyVarKind tv))) evvars

-- (mkConFull K) makes a fresh pattern for K, thus  (K ex1 ex2 d1 d2 x1 x2 x3)
mkConFull :: DataCon -> PmM (PmPat Id, [EvVar])
mkConFull con = do
  subst <- mkConSigSubst con
  let tycon    = dataConOrigTyCon  con                     -- Type constructors
      arg_tys  = substTys    subst (dataConOrigArgTys con) -- Argument types
      univ_tys = substTyVars subst (dataConUnivTyVars con) -- Universal variables (to instantiate tycon)
      ty       = mkTyConApp tycon univ_tys                 -- Type of the pattern
  evvars  <- mapM (nameType "varcon") $ substTheta subst (dataConTheta con) -- Constraints (all of them)
  con_pat <- PmConPat ty con <$> mapM freshPmVar arg_tys
  return (con_pat, evvars)

mkConSigSubst :: DataCon -> PmM TvSubst
-- SPJ: not convinced that we need to make fresh uniques
mkConSigSubst con = do -- INLINE THIS FUNCTION
  loc <- getSrcSpanDs
  (subst, _tvs) <- genInstSkolTyVars loc tkvs
  return subst
  where
    -- Both existential and unviversal type variables
    tyvars = dataConUnivTyVars con ++ dataConExTyVars con
    tkvs   = varSetElemsKvsFirst (closeOverKinds (mkVarSet tyvars))

{-
%************************************************************************
%*                                                                      *
\subsection{Helper functions}
%*                                                                      *
%************************************************************************
-}

-- Approximation
impliesGuard :: Delta -> PmGuard -> Bool
impliesGuard _ CanFail  = False
impliesGuard _ CantFail = True

-- Get the type of a pattern with all type synonyms unfolded
patTypeExpanded :: Pat Id -> Type
patTypeExpanded = expandTypeSynonyms . hsPatType

-- Used in all cases that we cannot handle. It generates a fresh variable
-- that has the same type as the given pattern and adds a guard next to it
unhandled_case :: Pat Id -> PmM [PmPat Id]
unhandled_case pat = do
  var_pat <- varFromPat pat
  return [var_pat, guardFailsPat]

-- Generate a variable from the initial pattern
-- that has the same type as the given
varFromPat :: Pat Id -> PmM (PmPat Id)
varFromPat = freshPmVar . patTypeExpanded

mViewConArgs :: DataCon -> HsConPatDetails Id -> PmM [PmPat Id]
mViewConArgs _ (PrefixCon ps)   = concat <$> mapM (mViewPat . unLoc) ps
mViewConArgs _ (InfixCon p1 p2) = concat <$> mapM (mViewPat . unLoc) [p1,p2]
mViewConArgs c (RecCon (HsRecFields fs _))
  | null fs   = instTypesPmM (dataConOrigArgTys c) >>= mapM freshPmVar
  | otherwise = do
      field_pats <- forM (dataConFieldLabels c) $ \lbl -> do
                      let orig_ty = dataConFieldType c lbl
                      ty <- instTypePmM orig_ty -- Expand type synonyms?? Should we? Should we not?
                      -- I am not convinced that we should do this here. Since we recursively call
                      -- mViewPat on the fresh wildcards we have created, we will generate fresh
                      -- variables then. Hence, maybe orig_ty will simply do the job here (I fear
                      -- we instantiate twice without a reason)
                      return (lbl, noLoc (WildPat ty))
                      -- return (lbl, noLoc (WildPat (dataConFieldType c lbl)))
      let all_pats = foldr (\(L _ (HsRecField id p _)) acc -> insertNm (getName (unLoc id)) p acc)
                           field_pats fs
      concat <$> mapM (mViewPat . unLoc . snd) all_pats
  where
    insertNm nm p [] = [(nm,p)]
    insertNm nm p (x@(n,_):xs)
      | nm == n    = (nm,p):xs
      | otherwise  = x : insertNm nm p xs

forces :: Forces -> Bool
forces Forces      = True
forces DoesntForce = False

or_forces :: Forces -> Forces -> Forces
or_forces f1 f2 | forces f1 || forces f2 = Forces
                | otherwise = DoesntForce

(<+++>) :: PmTriple -> PmTriple -> PmTriple
(<+++>) (PmTriple sc1 su1 sb1) (PmTriple sc2 su2 sb2)
  = PmTriple (sc1++sc2) (su1++su2) (or_forces sb1 sb2)

union_triples :: [PmTriple] -> PmTriple
union_triples = foldr (<+++>) empty_triple

-- Get all constructors in the family (including given)
allConstructors :: DataCon -> [DataCon]
allConstructors = tyConDataCons . dataConTyCon

-- maps only on the vectors
map_triple :: ([PmPat Id] -> [PmPat Id]) -> PmTriple -> PmTriple
map_triple f (PmTriple cs us fs) = PmTriple (mapv cs) (mapv us) fs
  where
    mapv = map $ \(delta, vec) -> (delta, f vec)

-- Fold the arguments back to the constructor:
-- (K p1 .. pn) q1 .. qn         ===> p1 .. pn q1 .. qn     (unfolding)
-- zip_con K (p1 .. pn q1 .. qn) ===> (K p1 .. pn) q1 .. qn (folding)
zip_con :: Type -> DataCon -> [PmPat id] -> [PmPat id]
zip_con ty con pats = (PmConPat ty con con_pats) : rest_pats
  where -- THIS HAS A PROBLEM. WE HAVE TO BE MORE SURE ABOUT THE CONSTRAINTS WE ARE GENERATING
    (con_pats, rest_pats) = splitAtList (dataConOrigArgTys con) pats

-- Add a bag of constraints in delta
addEvVarsDelta :: Bag EvVar -> Delta -> Delta
addEvVarsDelta evvars delta
  = delta { delta_evvars = delta_evvars delta `unionBags` evvars }

-- Add in delta the ev vars from the current local environment
addEnvEvVars :: Delta -> PmM Delta
addEnvEvVars delta = do
  evvars <- getDictsDs
  return (addEvVarsDelta evvars delta)

{-
%************************************************************************
%*                                                                      *
\subsection{Main Pattern Matching Check}
%*                                                                      *
%************************************************************************
-}

one_step :: UncoveredVec -> InVec -> PmM PmTriple

-- empty-empty
one_step (delta,[]) [] = do
  delta' <- addEnvEvVars delta
  return $ empty_triple { pmt_covered = [(delta',[])] }

-- any-var
one_step (delta, u : us) ((PmVarPat ty _var) : ps) = do
  evvar <- newEqPmM (pm_ty u) ty
  addDictsDs (unitBag evvar) $ do
    triple <- one_step (delta, us) ps
    return $ map_triple (u:) triple

-- con-con
one_step (delta, uvec@((PmConPat ty1 con1 ps1) : us)) ((PmConPat ty2 con2 ps2) : ps)
  | con1 == con2 = do
      evvar <- newEqPmM ty1 ty2 -- Too complex of a constraint you think??
      addDictsDs (unitBag evvar) $ do
        triple <- one_step (delta, ps1 ++ us) (ps2 ++ ps) -- should we do sth about the type constraints here?
        return $ map_triple (zip_con ty1 con1) triple
  | otherwise = do
      delta' <- addEnvEvVars delta
      return $ empty_triple { pmt_uncovered = [(delta',uvec)] }

-- var-con
one_step uvec@(_, (PmVarPat ty _var):_) vec@((PmConPat _ con _) : _) = do
  all_con_pats <- mapM mkConFull (allConstructors con)
  triples <- forM all_con_pats $ \(con_pat, evvars) -> do
    evvar <- newEqPmM ty (pm_ty con_pat) -- The variable must match with the constructor pattern (alpha ~ T a b c)
    addDictsDs (listToBag (evvar:evvars)) $
      one_step uvec vec
  let result = union_triples triples
  return $ result { pmt_forces = Forces }

-- any-guard
one_step (delta, us) ((PmGuardPat guard) : ps) = do
  let utriple | delta `impliesGuard` guard = empty_triple
              | otherwise                  = empty_triple { pmt_uncovered = [(delta,us)] }
  rec_triple <- one_step (delta, us) ps
  let result = utriple <+++> rec_triple
  return $ result { pmt_forces = Forces } -- Here we have the conservativity in forcing (a guard always forces sth)

-- lit-lit
one_step (delta, uvec@((p@(PmLitPat _ lit)) : us)) ((PmLitPat _ lit') : ps) -- lit-lit
  | lit /= lit' = do
      delta' <- addEnvEvVars delta
      return $ empty_triple { pmt_uncovered = [(delta',uvec)] }
  | otherwise   = map_triple (p:) <$> one_step (delta, us) ps

-- nlit-lit
one_step (delta, uvec@((PmLitCon ty var ls) : us)) (p@(PmLitPat _ lit) : ps) -- nlit-lit
  | lit `elem` ls = do
      delta' <- addEnvEvVars delta
      return $ empty_triple { pmt_uncovered = [(delta',uvec)] }
  | otherwise = do
      rec_triple <- map_triple (p:) <$> one_step (delta, us) ps
      let utriple = empty_triple { pmt_uncovered = [(delta, (PmLitCon ty var (lit:ls)) : us)] }
      return $ utriple <+++> rec_triple

-- var-lit
one_step (delta, (PmVarPat ty var ) : us) ((p@(PmLitPat _ty2 lit)) : ps) = do
  rec_triple <- map_triple (p:) <$> one_step (delta, us) ps
  let utriple = empty_triple { pmt_uncovered = [(delta, (PmLitCon ty var [lit]) : us)] }
      result  = utriple <+++> rec_triple
  return $ result { pmt_forces = Forces }

one_step _ _ = give_up

{-
Note [Pattern match check give up]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
There are some cases where we cannot perform the check. A simple example is
trac #322:
\begin{verbatim}
  f :: Maybe Int -> Int
  f 1 = 1
  f Nothing = 2
  f _ = 3
\end{verbatim}

In this case, the first line is compiled as
\begin{verbatim}
  f x | x == fromInteger 1 = 1
\end{verbatim}

To check this match, we should perform arbitrary computations at compile time
(@fromInteger 1@) which is highly undesirable. Hence, we simply give up by
returning a @Nothing@.
-}

-- Call one_step on all uncovered vectors and combine the results
one_full_step :: [UncoveredVec] -> InVec -> PmM PmTriple
one_full_step uncovered clause = do
  foldM (\acc uvec -> do
            triple <- one_step uvec clause
            return (triple <+++> acc))
        empty_triple
        uncovered

-- | External interface. Takes:
--   * The types of the arguments
--   * The list of EquationInfo to check
-- and returns a (Maybe PmResult) -- see Note [Pattern match check give up]
checkpm :: [Type] -> [EquationInfo] -> DsM (Maybe PmResult)
checkpm tys eq_info = do
  res <- tryM (checkpmPmM tys eq_info)
  case res of
    Left _    -> return Nothing
    Right ans -> return (Just ans)

-- Check the match in PmM monad. Instead of passing the types from the
-- signature to checkpm', we simply use the type information to initialize
-- the first set of uncovered vectors (i.e., a single wildcard-vector).
checkpmPmM :: [Type] -> [EquationInfo] -> PmM PmResult
checkpmPmM _ [] = return ([],[],[])
checkpmPmM tys' eq_infos = do
  let tys = map (toTcType . expandTypeSynonyms) tys' -- Not sure if this is correct
  init_pats  <- mapM freshPmVar tys -- should we expand?
  init_delta <- addEnvEvVars empty_delta
  checkpm' [(init_delta, init_pats)] eq_infos

-- Worker (recursive)
checkpm' :: [UncoveredVec] -> [EquationInfo] -> PmM PmResult
checkpm' uncovered_set [] = return ([],[],uncovered_set)
checkpm' uncovered_set (eq_info:eq_infos) = do
  invec <- preprocess_match eq_info
  PmTriple cs us fs <- one_full_step uncovered_set invec
  covers_wt <- anyM isSatisfiable cs
  let (redundant, inaccessible)
        | covers_wt = ([],        [])        -- At least one of cs is satisfiable
        | forces fs = ([],        [eq_info]) -- inaccessible rhs
        | otherwise = ([eq_info], [])        -- redundant
  accepted_us <- filterM isSatisfiable us -- MAYBE WE NEED TO CHECK EVERY CLAUSE AS SOON AS IT IS PRODUCED

  (redundants, inaccessibles, missing) <- checkpm' accepted_us eq_infos
  return (redundant ++ redundants, inaccessible ++ inaccessibles, missing)

{-
%************************************************************************
%*                                                                      *
              Interface to the solver
%*                                                                      *
%************************************************************************
-}

{-
-- KEEP THIS HOLE FOR NOW, TO MAKE SURE THAT WE ARE WELL_TYPED
-- We crash somewhere else, even without the solver. Some of my transformations
-- (on fresh term, type and kind variables) I guess that mess everything up
isSatisfiable :: (Delta, [PmPat Id]) -> PmM Bool
isSatisfiable _ = return True
-}

-- | This is a hole for a contradiction checker. The actual type must be
-- Delta -> Bool. It should check whether are satisfiable both:
--  * The type constraints
--  * THe term constraints
isSatisfiable :: (Delta, [PmPat Id]) -> PmM Bool
isSatisfiable (Delta { delta_evvars = evs }, _)
  = do { ((_warns, errs), res) <- initTcDsForSolver $
                                   tcCheckSatisfiability evs
       ; case res of
            Just sat -> return sat
            Nothing  -> pprPanic "isSatisfiable" (vcat $ pprErrMsgBagWithLoc errs) }


{-
%************************************************************************
%*                                                                      *
\subsection{Pretty Printing}
%*                                                                      *
%************************************************************************
-}

instance (OutputableBndr id, Outputable id) => Outputable (PmLit id) where
  ppr (PmLit lit)           = pmPprHsLit lit -- don't use just ppr to avoid all the hashes
  ppr (PmOLit l Nothing  _) = ppr l
  ppr (PmOLit l (Just _) _) = char '-' <> ppr l

instance (OutputableBndr id, Outputable id) => Outputable (PmPat id) where
  ppr (PmGuardPat pm_guard)       = braces $ ptext (sLit "g#")  <> ppr pm_guard -- temporary
  ppr (PmVarPat _ pm_variable)    = ppr pm_variable
  ppr (PmConPat _ pm_con pm_args) | null pm_args = ppr pm_con
                                  | otherwise    = parens $ ppr pm_con <+> hsep (map ppr pm_args)
  ppr (PmLitPat _ pm_literal)     = ppr pm_literal
  ppr (PmLitCon _ var lits)       = ((ppr var) <>) . braces . hcat . punctuate comma . map ppr $ lits

-- Only for debugging
instance Outputable Delta where
  ppr (Delta evvars _) = ppr $ mapBag varType evvars

-- Needs improvement. Now it is too chatty with constraints and does not show
-- PmLitCon s in a nice way
pprUncovered :: UncoveredVec -> SDoc
pprUncovered (delta, uvec) = vcat [ ppr uvec
                                  , nest 4 (ptext (sLit "With constraints:") <+> ppr delta) ]

-- PLACE IT SOMEWHERE ELSE IN THE FILE
type PmM a = DsM a -- just a renaming to remove later (maybe keep this)

-- Give up checking the match
give_up :: PmM a
give_up = failM

-- Fresh type with fresh kind
instTypePmM :: Type -> PmM Type
instTypePmM ty = do
  loc <- getSrcSpanDs
  (subst, _tkvs) <- genInstSkolTyVars loc tkvs
  return $ substTy subst ty
  where
    tvs  = tyVarsOfType ty
    tkvs = varSetElemsKvsFirst (closeOverKinds tvs)

instTypesPmM :: [Type] -> PmM [Type]
instTypesPmM tys = do
  loc <- getSrcSpanDs                               -- Location from Monad
  (subst, _tkvs) <- genInstSkolTyVars loc tkvs      -- Generate a substitution for all kind and type variables
  return $ substTys subst tys                       -- Apply it to the original types
  where
    tvs  = tyVarsOfTypes tys                        -- All type variables
    tkvs = varSetElemsKvsFirst (closeOverKinds tvs) -- All tvs and kvs

