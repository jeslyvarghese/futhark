{-# LANGUAGE GeneralizedNewtypeDeriving, TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses #-}
module L0C.HOTrans.Fusion ( fuseProg )
  where

import Control.Monad.State
import Control.Applicative
import Control.Monad.Reader

import Data.Hashable
import Data.Maybe
import Data.Loc

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet      as HS

import L0C.L0
import L0C.MonadFreshNames
import L0C.EnablingOpts.EnablingOptDriver
import L0C.HOTrans.Composing
import L0C.HOTrans.LoopKernel
import L0C.HORepresentation.SOAC (SOAC)
import qualified L0C.HORepresentation.SOAC as SOAC

data FusionGEnv = FusionGEnv {
    soacs      :: HM.HashMap VName [VName]
  -- ^ Mapping from variable name to its entire family.
  , arrsInScope:: HS.HashSet VName
  , fusedRes   :: FusedRes
  , program    :: Prog
  }

newtype FusionGM a = FusionGM (StateT VNameSource (ReaderT FusionGEnv (Either EnablingOptError)) a)
    deriving (  MonadState VNameSource,
                MonadReader FusionGEnv,
                Monad, Applicative, Functor )

instance MonadFreshNames VName FusionGM where
  getNameSource = get
  putNameSource = put

------------------------------------------------------------------------
--- Monadic Helpers: bind/new/runFusionGatherM, etc                      ---
------------------------------------------------------------------------


-- | Binds an array name to the set of used-array vars
bindVar :: FusionGEnv -> VName -> FusionGEnv
bindVar env name =
  env { arrsInScope = HS.insert name $ arrsInScope env }

bindVars :: FusionGEnv -> [VName] -> FusionGEnv
bindVars = foldl bindVar

bindingIdents :: [Ident] -> FusionGM a -> FusionGM a
bindingIdents idds = local (`bindVars` namesOfArrays idds)
  where namesOfArrays = map identName . filter (not . basicType . identType)

binding :: TupIdent -> FusionGM a -> FusionGM a
binding = bindingIdents . patIdents

-- | Binds an array name to the set of soac-produced vars
bindPatVar :: [VName] -> FusionGEnv -> VName -> FusionGEnv
bindPatVar faml env nm = env { soacs       = HM.insert nm faml $ soacs env
                             , arrsInScope = HS.insert nm      $ arrsInScope env
                             }

bindPatVars :: [VName] -> FusionGEnv -> FusionGEnv
bindPatVars names env = foldl (bindPatVar names) env names

bindPat :: TupIdent -> FusionGM a -> FusionGM a
bindPat pat = do
  let nms = map identName $ patIdents pat
  local $ bindPatVars nms

-- | Binds the fusion result to the environment.
bindRes :: FusedRes -> FusionGM a -> FusionGM a
bindRes rrr = local (\x -> x { fusedRes = rrr })

-- | The fusion transformation runs in this monad.  The mutable
-- state refers to the fresh-names engine.
-- The reader hides the vtable that associates ... to ... (fill in, please).
-- The 'Either' monad is used for error handling.
runFusionGatherM :: Prog -> FusionGM a -> FusionGEnv -> Either EnablingOptError a
runFusionGatherM prog (FusionGM a) =
    runReaderT (evalStateT a (newNameSourceForProg prog))

badFusionGM :: EnablingOptError -> FusionGM a
badFusionGM = FusionGM . lift . lift . Left

------------------------------------------------------------------------
--- Fusion Entry Points: gather the to-be-fused kernels@pgm level    ---
---    and fuse them in a second pass!                               ---
------------------------------------------------------------------------

fuseProg :: Prog -> Either EnablingOptError (Bool, Prog)
fuseProg prog = do
  let env = FusionGEnv { soacs = HM.empty, arrsInScope = HS.empty, fusedRes = mkFreshFusionRes, program = prog }
  let funs= progFunctions prog
  ks <- runFusionGatherM prog (mapM fusionGatherFun funs) env
  let ks'    = map cleanFusionResult ks
  let succc = any rsucc ks'
  if not succc
  then return (False, prog)
  else do funs' <- runFusionGatherM prog (zipWithM fuseInFun ks' funs) env
          return (True, Prog funs')

fusionGatherFun :: FunDec -> FusionGM FusedRes
fusionGatherFun (_, _, _, body, _) = fusionGatherExp mkFreshFusionRes body

fuseInFun :: FusedRes -> FunDec -> FusionGM FunDec
fuseInFun res (fnm, rtp, idds, body, pos) = do
  body' <- bindRes res $ fuseInExp body
  return (fnm, rtp, idds, body', pos)


---------------------------------------------------
---------------------------------------------------
---- RESULT's Data Structure
---------------------------------------------------
---------------------------------------------------

-- | A type used for (hopefully) uniquely referring a producer SOAC.
-- The uniquely identifying value is the name of the first array
-- returned from the SOAC.
newtype KernName = KernName { unKernName :: VName }
  deriving (Eq, Ord, Show)

instance Hashable KernName where
  hashWithSalt salt = hashWithSalt salt . unKernName

data FusedRes = FusedRes {
    rsucc :: Bool
  -- ^ Whether we have fused something anywhere.

  , outArr     :: HM.HashMap VName KernName
  -- ^ Associates an array to the name of the
  -- SOAC kernel that has produced it.

  , inpArr     :: HM.HashMap VName (HS.HashSet KernName)
  -- ^ Associates an array to the names of the
  -- SOAC kernels that uses it. These sets include
  -- only the SOAC input arrays used as full variables, i.e., no `a[i]'.

  , unfusable  :: HS.HashSet VName
  -- ^ the (names of) arrays that are not fusable, i.e.,
  --
  --   1. they are either used other than input to SOAC kernels, or
  --
  --   2. are used as input to at least two different kernels that
  --      are not located on disjoint control-flow branches, or
  --
  --   3. are used in the lambda expression of SOACs

  , kernels    :: HM.HashMap KernName FusedKer
  -- ^ The map recording the uses
  }

isInpArrInResModKers :: FusedRes -> HS.HashSet KernName -> VName -> Bool
isInpArrInResModKers ress kers nm =
  case HM.lookup nm (inpArr ress) of
    Nothing -> False
    Just s  -> not $ HS.null $ s `HS.difference` kers

getKersWithInpArrs :: FusedRes -> [VName] -> HS.HashSet KernName
getKersWithInpArrs ress =
  HS.unions . mapMaybe (`HM.lookup` inpArr ress)

-- | extend the set of names to include all the names
--     produced via SOACs (by querring the vtable's soac)
expandSoacInpArr :: [VName] -> FusionGM [VName]
expandSoacInpArr =
    foldM (\y nm -> do bnd <- asks $ HM.lookup nm . soacs
                       case bnd of
                         Nothing  -> return (y++[nm])
                         Just nns -> return (y++nns )
          ) []

----------------------------------------------------------------------
----------------------------------------------------------------------

soacInputs :: SOAC -> FusionGM ([VName], [VName])
soacInputs soac = do
  let (inp_idds, other_idds) = getIdentArr $ SOAC.inputs soac
      (inp_nms0,other_nms0)  = (map identName inp_idds, map identName other_idds)
  inp_nms   <- expandSoacInpArr   inp_nms0
  other_nms <- expandSoacInpArr other_nms0
  return (inp_nms, other_nms)

addNewKer :: FusedRes -> ([Ident], SOAC) -> FusionGM FusedRes
addNewKer res (idd, soac) = do
  (inp_nms, other_nms) <- soacInputs soac

  let used_inps = filter (isInpArrInResModKers res HS.empty) inp_nms
  let ufs = HS.unions [unfusable res, HS.fromList used_inps, HS.fromList other_nms]

  addNewKerWithUnfusable res (idd, soac) ufs

addNewKerWithUnfusable :: FusedRes -> ([Ident], SOAC) -> HS.HashSet VName -> FusionGM FusedRes
addNewKerWithUnfusable res (idd, soac) ufs = do
  nm_ker <- KernName <$> newVName "ker"
  let new_ker = newKernel idd soac
      out_nms = map identName idd
      comb    = HM.unionWith HS.union
      os' = HM.fromList [(arr,nm_ker) | arr <- out_nms]
            `HM.union` outArr res
      is' = HM.fromList [(identName arr,HS.singleton nm_ker)
                         | arr <- mapMaybe SOAC.inputArray $ SOAC.inputs soac]
            `comb` inpArr res
  return $ FusedRes (rsucc res) os' is' ufs
           (HM.insert nm_ker new_ker (kernels res))

-- map, reduce, redomap
greedyFuse :: Bool -> HS.HashSet VName -> FusedRes -> ([Ident], SOAC) -> FusionGM FusedRes
greedyFuse is_repl lam_used_nms res (out_idds, soac) = do
    -- Assumption: the free vars in lambda are already in
    -- 'unfusable res'.
    (inp_nms, other_nms) <- soacInputs soac

    let out_nms      = map identName out_idds
    -- Conditions for fusion:
    --   (i) none of `out_idds' belongs to the unfusable set.
    --  (ii) there are some kernels that use some of `out_idds' as inputs
    let isUnfusable    = (`HS.member` unfusable res)
        not_unfusable  = is_repl || not (any isUnfusable out_nms)
        to_fuse_knmSet = getKersWithInpArrs res out_nms
        to_fuse_knms   = HS.toList to_fuse_knmSet
        lookup_kern k  = case HM.lookup k (kernels res) of
                           Nothing  -> badFusionGM $ EnablingOptError (srclocOf soac)
                                       ("In Fusion.hs, greedyFuse, comp of to_fuse_kers: "
                                        ++ "kernel name not found in kernels field!")
                           Just ker -> return ker

    to_fuse_kers <- mapM lookup_kern to_fuse_knms

    -- all kernels has to be compatible for fusion, e.g., if
    -- the kernel is a map, and the current soac is a filter,
    -- then they cannot be fused
    (ok_kers_compat, fused_kers) <- do
      kers <- mapM (attemptFusion out_idds soac) to_fuse_kers
      case sequence kers of
        Nothing    -> return (False, [])
        Just kers' -> return (True, kers')

    -- check whether fusing @soac@ will violate any in-place update
    --    restriction, e.g., would move an input array past its in-place update.
    let all_used_names = HS.toList $ HS.unions [lam_used_nms, HS.fromList inp_nms, HS.fromList other_nms]
        has_inplace ker = any (`HS.member` inplace ker) all_used_names
        ok_inplace = not $ any has_inplace to_fuse_kers

    -- compute whether @soac@ is fusable or not
    let is_fusable = not_unfusable && not (null to_fuse_kers) && ok_inplace && ok_kers_compat

    --  (i) inparr ids other than vars will be added to unfusable list,
    -- (ii) will also become part of the unfusable set the inparr vars
    --         that also appear as inparr of another kernel,
    --         BUT which said kernel is not the one we are fusing with (now)!
    let mod_kerS  = if is_fusable then to_fuse_knmSet else HS.empty
    let used_inps = filter (isInpArrInResModKers res mod_kerS) inp_nms
    let ufs       = HS.unions [unfusable res, HS.fromList used_inps,
                               HS.fromList other_nms `HS.difference`
                               HS.fromList (map identName $ mapMaybe SOAC.inputArray $ SOAC.inputs soac)]
    let comb      = HM.unionWith HS.union

    if not is_fusable then
      if is_repl then return res
      else -- nothing to fuse, add a new soac kernel to the result
        addNewKerWithUnfusable res (out_idds, soac) ufs
     else do
       -- Need to suitably update `inpArr':
       --   (i) first remove the inpArr bindings of the old kernel
       --  (ii) then add the inpArr bindings of the new kernel
       let inpArr' =
             foldl (\inpa (kold, knew, knm) ->
                      let inpa' =
                            HS.foldl'
                                (\inpp nm ->
                                   case HM.lookup nm inpp of
                                     Nothing -> inpp
                                     Just s  -> let new_set = HS.delete knm s
                                                in if HS.null new_set
                                                   then HM.delete nm         inpp
                                                   else HM.insert nm new_set inpp
                                )
                            inpa $ HS.map identName $ arrInputs kold
                      in HM.fromList [ (k, HS.singleton knm)
                                        | k <- HS.toList $ HS.map identName (arrInputs knew) ]
                           `comb` inpa')
             (inpArr res) (zip3 to_fuse_kers fused_kers to_fuse_knms)
       -- Update the kernels map
       let kernels' = HM.fromList (zip to_fuse_knms fused_kers)
                      `HM.union` kernels res

       -- nothing to do for `outArr' (since we have not added a new kernel)
       return $ FusedRes True (outArr res) inpArr' ufs kernels'

attemptFusion :: [Ident] -> SOAC -> FusedKer -> FusionGM (Maybe FusedKer)
attemptFusion outIds soac ker
  | Just (soac', ots) <- optimizeSOAC Nothing soac =
      let ker' = map (outputsToInput ots) (inputs ker) `setInputs` ker
      in attemptFusion outIds soac' ker'
  | Just ker' <- optimizeKernel (Just outIds) ker =
      attemptFusion outIds soac ker'
  | isCompatibleKer (outIds, soac) ker =
      Just <$> fuseSOACwithKer (outIds, soac) ker
  | otherwise =
      return Nothing

fuseSOACwithKer :: ([Ident], SOAC) -> FusedKer -> FusionGM FusedKer
fuseSOACwithKer (out_ids1, soac1) ker = do
  -- We are fusing soac1 into soac2, i.e, the output of soac1 is going
  -- into soac2.
  let soac2 = fsoac ker
      out_ids2 = outputs ker
      cs1      = SOAC.certificates soac1
      cs2      = SOAC.certificates soac2
  case (soac2, soac1) of
      -- first get rid of the cases that can be solved by
      -- a bit of soac rewriting.
    (SOAC.ReduceT _ lam ne arrs loc, SOAC.MapT   {}) -> do
      let soac2' = SOAC.RedomapT (cs1++cs2) lam lam ne arrs loc
          ker'   = ker { fsoac = soac2'
                       , outputs = out_ids2 }
      fuseSOACwithKer (out_ids1, soac1) ker'
    _ -> do -- treat the complicated cases!
            let inp1_arr = SOAC.inputs soac1
                inp2_arr = SOAC.inputs soac2
                lam1     = SOAC.lambda soac1
                lam2     = SOAC.lambda soac2

            res_soac <-
              case (soac2,soac1) of
                ----------------------------------------------------
                -- The Fusions that are semantically map fusions:
                ----------------------------------------------------
                (SOAC.MapT _ _ _ pos, SOAC.MapT    {}) -> do
                  let (res_lam, new_inp) = fuseMaps lam1 inp1_arr out_ids1 lam2 inp2_arr
                  return $ SOAC.MapT (cs1++cs2) res_lam new_inp pos
                (SOAC.RedomapT _ lam21 _ ne _ pos, SOAC.MapT {})-> do
                  let (res_lam, new_inp) = fuseMaps lam1 inp1_arr out_ids1 lam2 inp2_arr
                  return $ SOAC.RedomapT (cs1++cs2) lam21 res_lam ne new_inp pos

                ----------------------------------------------------
                -- The Fusions that are semantically filter fusions:
                ----------------------------------------------------
                (SOAC.ReduceT _ _ ne _ pos, SOAC.FilterT {}) -> do
                  name <- newVName "check"
                  let (res_lam, new_inp) = fuseFilterIntoFold lam1 inp1_arr out_ids1 lam2 inp2_arr name
                  return $ SOAC.ReduceT (cs1++cs2) res_lam ne new_inp pos
                (SOAC.RedomapT _ lam21 _ nes _ pos, SOAC.FilterT {}) -> do
                  name <- newVName "check"
                  let (res_lam, new_inp) = fuseFilterIntoFold lam1 inp1_arr out_ids1 lam2 inp2_arr name
                  return $ SOAC.RedomapT (cs1++cs2) lam21 res_lam nes new_inp pos
                (SOAC.FilterT _ _ _ pos, SOAC.FilterT {}) -> do
                  name <- newVName "check"
                  let (res_lam, new_inp) = fuseFilters lam1 inp1_arr out_ids1 lam2 inp2_arr name
                  return $ SOAC.FilterT (cs1++cs2) res_lam new_inp pos

                ----------------------------------------------------
                -- Unfusable: should not have reached here!!!
                ----------------------------------------------------
                _ -> badFusionGM $ EnablingOptError (srclocOf soac1)
                                    ("In Fusion.hs, fuseSOACwithKer: fusion not supported "
                                     ++ "(soac2,soac1): (" ++ ppExp (SOAC.toExp soac2)++", "++ppExp (SOAC.toExp soac1))
            -- END CASE(soac2,soac1)

            -- soac_new1<- trace ("\nFUSED KERNEL: " ++ (nameToString . identName) (head out_ids1) ++ " : " ++ ppExp res_soac ++ " Input arrs: " ++ concatMap (nameToString . identName) inp_new) (return res_soac)

            let fusedVars_new = fusedVars ker++out_ids1
            return $ ker { fsoac = res_soac
                         , outputs = out_ids2
                         , fusedVars = fusedVars_new
                         }

------------------------------------------------------------------------
------------------------------------------------------------------------
------------------------------------------------------------------------
--- Fusion Gather for EXPRESSIONS, i.e., where work is being done:   ---
---    i) bottom-up AbSyn traversal (backward analysis)              ---
---   ii) soacs are fused greedily iff does not duplicate computation---
--- E.g., (y1, y2, y3) = mapT(f, x1, x2[i])                          ---
---       (z1, z2)     = mapT(g1, y1, y2)                            ---
---       (q1, q2)     = mapT(g2, y3, z1, a, y3)                     ---
---       res          = reduce(op, ne, q1, q2, z2, y1, y3)          ---
--- can be fused if y1,y2,y3, z1,z2, q1,q2 are not used elsewhere:   ---
---       res = redomap(op, \(x1,x2i,a)->                            ---
---                             let (y1,y2,y3) = f (x1, x2i)       in---
---                             let (z1,z2)    = g1(y1, y2)        in---
---                             let (q1,q2)    = g2(y3, z1, a, y3) in---
---                             (q1, q2, z2, y1, y3)                 ---
---                     x1, x2[i], a)                                ---
------------------------------------------------------------------------
------------------------------------------------------------------------
------------------------------------------------------------------------
fusionGatherExp :: FusedRes -> Exp -> FusionGM FusedRes

----------------------------------------------
--- Let-Pattern: most important construct
----------------------------------------------

fusionGatherExp fres (LetPat pat e body _)
  | Right soac <- SOAC.fromExp e =
      case soac of
        SOAC.MapT _ lam _ _ -> do
          bres  <- bindPat pat $ fusionGatherExp fres body
          (used_lam, blres) <- fusionGatherLam (HS.empty, bres) lam
          greedyFuse False used_lam blres (patIdents pat, soac)

        SOAC.FilterT _ lam _ _ -> do
          bres  <- bindPat pat $ fusionGatherExp fres body
          (used_lam, blres) <- fusionGatherLam (HS.empty, bres) lam
          greedyFuse False used_lam blres (patIdents pat, soac)

        SOAC.ReduceT _ lam nes _ loc -> do
          -- a reduce always starts a new kernel
          bres  <- bindPat pat $ fusionGatherExp fres body
          bres' <- fusionGatherExp bres $ TupLit nes loc
          (_, blres) <- fusionGatherLam (HS.empty, bres') lam
          addNewKer blres (patIdents pat, soac)

        SOAC.RedomapT _ outer_red inner_red ne _ loc -> do
          -- a redomap always starts a new kernel
          (_, lres)  <- foldM fusionGatherLam (HS.empty, fres) [outer_red, inner_red]
          bres  <- bindPat pat $ fusionGatherExp lres body
          bres' <- fusionGatherExp bres $ TupLit ne loc
          addNewKer bres' (patIdents pat, soac)

        SOAC.ScanT _ lam nes _ loc -> do
          -- NOT FUSABLE (probably), but still add as kernel, as
          -- optimisations like ISWIM may make it fusable.
          bres  <- bindPat pat $ fusionGatherExp fres body
          (used_lam, blres) <- fusionGatherLam (HS.empty, bres) lam
          blres' <- fusionGatherExp blres $ TupLit nes loc
          greedyFuse False used_lam blres' (patIdents pat, soac)

fusionGatherExp _ (LetPat _ e _ loc)
  | Left (SOAC.InvalidArrayInput inpe) <- SOAC.fromExp e =
    badFusionGM $ EnablingOptError loc
                  ("In Fusion.hs, "++ppExp inpe++" is not valid array input.")


fusionGatherExp fres (LetPat pat (Replicate n el loc) body _) = do
    bres <- bindPat pat $ fusionGatherExp fres body
    -- Implemented inplace: gets the variables in `n` and `el`
    (used_set, bres') <- getUnfusableSet loc bres [n,el]
    repl_idnm <- newVName "repl_x"
    let repl_id = Ident repl_idnm (Elem Int) loc
        (lame, rwt) = case typeOf el of
                        Elem (Tuple ets) -> (el, ets)
                        t                -> (TupLit [el] loc, [t])
        repl_lam = TupleLambda [toParam repl_id] lame (map toDecl rwt) loc
        soac_repl= SOAC.MapT [] repl_lam [SOAC.Iota n] loc
    greedyFuse True used_set bres' (patIdents pat, soac_repl)

fusionGatherExp fres (LetPat pat e body _) = do
    let pat_vars = map Var $ patIdents pat
    bres <- binding pat $ fusionGatherExp fres body
    foldM fusionGatherExp bres (e:pat_vars)


-----------------------------------------
---- Var/Index/LetWith/Do-Loop/If    ----
-----------------------------------------

fusionGatherExp fres (Var idd) =
    -- IF idd is an array THEN ADD it to the unfusable set!
    case identType idd of
        Array{} -> return fres { unfusable = HS.insert (identName idd) (unfusable fres) }
        _       -> return fres

fusionGatherExp fres (Index _ idd _ inds _ _) =
    foldM fusionGatherExp fres (Var idd : inds)

fusionGatherExp fres (LetWith _ id1 id0 _ inds elm body _) = do
    bres  <- bindingIdents [id1] $ fusionGatherExp fres body

    let pat_vars = [Var id0, Var id1]
    fres' <- foldM fusionGatherExp bres (elm : inds ++ pat_vars)
    let (ker_nms, kers) = unzip $ HM.toList $ kernels fres'

    -- Now add the aliases of id0 (itself included) to the `inplace'
    -- field of any existent kernel.
    let inplace_aliases = HS.toList $ aliases $ typeOf $ Var id0
    let kers' = map (\ k -> let inplace' = foldl (flip HS.insert) (inplace k) inplace_aliases
                            in  k { inplace = inplace' }
                    ) kers
    let new_kernels = HM.fromList $ zip ker_nms kers'
    return $ fres' { kernels = new_kernels }

fusionGatherExp fres (DoLoop merge_pat ini_val _ ub loop_body let_body _) = do
    letbres <- binding merge_pat $ fusionGatherExp fres let_body

    let pat_vars = map Var $ patIdents merge_pat
    fres' <- foldM fusionGatherExp letbres (ini_val:ub:pat_vars)

    let null_res = mkFreshFusionRes
    new_res <- binding merge_pat $ fusionGatherExp null_res loop_body
    -- make the inpArr unfusable, so that they
    -- cannot be fused from outside the loop:
    let (inp_arrs, _) = unzip $ HM.toList $ inpArr new_res
    let new_res' = new_res { unfusable = foldl (flip HS.insert) (unfusable new_res) inp_arrs }
    -- merge new_res with fres'
    return $ unionFusionRes new_res' fres'

fusionGatherExp fres (If cond e_then e_else _ _) = do
    let null_res = mkFreshFusionRes
    then_res <- fusionGatherExp null_res e_then
    else_res <- fusionGatherExp null_res e_else
    let both_res = unionFusionRes then_res else_res
    fres'    <- fusionGatherExp fres cond
    mergeFusionRes fres' both_res

-----------------------------------------------------------------------------------
--- Errors: all SOACs, both the regular ones (because they cannot appear in prg)---
---         and the 2 ones (because normalization ensures they appear directly  ---
---         in let exp, i.e., let x = e)
-----------------------------------------------------------------------------------

fusionGatherExp _ (Map      _ _ _     pos) = errorIllegal "map"     pos
fusionGatherExp _ (Reduce   _ _ _ _   pos) = errorIllegal "reduce"  pos
fusionGatherExp _ (Scan     _ _ _ _   pos) = errorIllegal "scan"    pos
fusionGatherExp _ (Filter   _ _ _     pos) = errorIllegal "filter"  pos
fusionGatherExp _ (Redomap  _ _ _ _ _ pos) = errorIllegal "redomap"  pos

fusionGatherExp _ (MapT     _ _ _     pos) = errorIllegal "mapT"    pos
fusionGatherExp _ (ReduceT  _ _ _ _   pos) = errorIllegal "reduceT" pos
fusionGatherExp _ (ScanT    _ _ _ _   pos) = errorIllegal "scanT"   pos
fusionGatherExp _ (FilterT  _ _ _     pos) = errorIllegal "filterT" pos
fusionGatherExp _ (RedomapT _ _ _ _ _ pos) = errorIllegal "redomapT" pos

-----------------------------------
---- Generic Traversal         ----
-----------------------------------

fusionGatherExp fres e = do
    let foldstct = identityFolder { foldOnExp = fusionGatherExp }
    foldExpM foldstct fres e

-- Lambdas create a new scope.  Disallow fusing from outside lambda by
-- adding inp_arrs to the unfusable set.
fusionGatherLam :: (HS.HashSet VName, FusedRes) -> TupleLambda -> FusionGM (HS.HashSet VName, FusedRes)
fusionGatherLam (u_set,fres) (TupleLambda idds body _ _) = do
    let null_res = mkFreshFusionRes
    new_res <- bindingIdents (map fromParam idds) $ fusionGatherExp null_res body
    -- make the inpArr unfusable, so that they
    -- cannot be fused from outside the lambda:
    let inp_arrs = HS.fromList $ HM.keys $ inpArr new_res
    let unfus = unfusable new_res `HS.union` inp_arrs
    bnds <- asks arrsInScope
    let unfus'  = unfus `HS.intersection` bnds
    -- merge fres with new_res'
    let new_res' = new_res { unfusable = unfus' }
    -- merge new_res with fres'
    return (u_set `HS.union` unfus', unionFusionRes new_res' fres)

getUnfusableSet :: SrcLoc -> FusedRes -> [Exp] -> FusionGM (HS.HashSet VName, FusedRes)
getUnfusableSet pos fres args = do
    -- assuming program is normalized then args
    -- can only contribute to the unfusable set
    let null_res = mkFreshFusionRes
    new_res <- foldM fusionGatherExp null_res args
    if not (HM.null (outArr  new_res)) || not (HM.null (inpArr new_res)) ||
       not (HM.null (kernels new_res)) || rsucc new_res
    then badFusionGM $ EnablingOptError pos $
                        "In Fusion.hs, getUnfusableSet, broken invariant!"
                        ++ " Unnormalized program: " ++ concatMap ppExp args
    else return ( unfusable new_res,
                  fres { unfusable = unfusable fres `HS.union` unfusable new_res }
                )

-------------------------------------------------------------
-------------------------------------------------------------
--- FINALLY, Substitute the kernels in function
-------------------------------------------------------------
-------------------------------------------------------------

fuseInExp :: Exp -> FusionGM Exp

----------------------------------------------
--- Let-Pattern: most important construct
----------------------------------------------

fuseInExp (LetPat pat e body pos) =
  case SOAC.fromExp e of
    Right soac ->
      replaceSOAC pat soac <*> fuseInExp body
    _ -> do
      body' <- fuseInExp body
      e'    <- fuseInExp e
      return $ LetPat pat e' body' pos

-- Errors: regular SOAC, because they cannot appear in prg.  The
-- tuple-SOACs can appear if they are not used in fusion
fuseInExp (Map      _ _ _     pos) = errorIllegalFus "map"     pos
fuseInExp (Reduce   _ _ _ _   pos) = errorIllegalFus "reduce"  pos
fuseInExp (Scan     _ _ _ _   pos) = errorIllegalFus "scan"    pos
fuseInExp (Filter   _ _ _     pos) = errorIllegalFus "filter"  pos
fuseInExp (Redomap  _ _ _ _ _ pos) = errorIllegalFus "redomap"  pos

fuseInExp e = mapExpM fuseIn e
  where fuseIn = identityMapper {
                   mapOnExp         = fuseInExp
                 , mapOnTupleLambda = fuseInLambda
                 }

fuseInLambda :: TupleLambda -> FusionGM TupleLambda
fuseInLambda (TupleLambda params body rtp pos) = do
  body' <- fuseInExp body
  return $ TupleLambda params body' rtp pos

replaceSOAC :: TupIdent -> SOAC -> FusionGM (Exp -> Exp)
replaceSOAC pat soac = do
  fres  <- asks fusedRes
  let loc     = srclocOf soac
  let pat_nm  = identName $ head $ patIdents pat
  let bind e = return $ \body -> LetPat pat e body $ srclocOf pat
  case HM.lookup pat_nm (outArr fres) of
    Nothing  -> bind =<< fuseInExp (SOAC.toExp soac)
    Just knm ->
      case HM.lookup knm (kernels fres) of
        Nothing  -> badFusionGM $ EnablingOptError loc
                                   ("In Fusion.hs, replaceSOAC, outArr in ker_name "
                                    ++"which is not in Res: "++textual (unKernName knm))
        Just ker -> do
          let new_soac = fsoac ker
              pat' = TupId (map Id $ outputs ker) loc
          if pat /= pat'
          then badFusionGM $ EnablingOptError loc
                              ("In Fusion.hs, replaceSOAC, "
                               ++" pat does not match kernel's pat: "++ppTupId pat)
          else if null $ fusedVars ker
               then badFusionGM $ EnablingOptError loc
                                   ("In Fusion.hs, replaceSOAC, unfused kernel "
                                    ++"still in result: "++ppTupId pat)
               -- then fuseInExp soac
               else do -- TRY MOVE THIS TO OUTER LEVEL!!!
                       let lam = SOAC.lambda new_soac
                       nmsrc <- get
                       prog  <- asks program
                       case normCopyOneTupleLambda prog nmsrc lam of
                          Left err             -> badFusionGM err
                          Right (nmsrc', lam') -> do
                            put nmsrc'
                            (_, nfres) <- fusionGatherLam (HS.empty, mkFreshFusionRes) lam'
                            let nfres' =  cleanFusionResult nfres
                            lam''      <- bindRes nfres' $ fuseInLambda lam'
                            transformOutput (outputTransform ker) (outputs ker) $
                              SOAC.setLambda lam'' new_soac

transformOutput :: [OutputTransform]
                -> [Ident] -> SOAC -> FusionGM (Exp -> Exp)
transformOutput trnss outIds soac = do
  (outIds', bind) <- manyTransform outIds trnss
  return $ \body -> LetPat (TupId (map Id outIds') loc)
                    (SOAC.toExp soac) (bind body) loc
  where loc = srclocOf soac
        newNames = mapM $ \idd -> do
                     name <- newVName $ (++"_trns") $
                             nameToString $ baseName $ identName idd
                     return $ idd { identName = name }
        manyTransform ids = foldM oneTransform (ids, id) . reverse
        oneTransform (ids, inner) trn = do
          ids' <- newNames ids
          let lets = zipWith (bindTransform trn) ids ids'
              bnds = foldl (.) id lets
          return (ids', bnds . inner)
        bindTransform trn to from body =
          LetPat (Id to) (applyTransform trn from loc) body loc

---------------------------------------------------
---------------------------------------------------
---- HELPERS
---------------------------------------------------
---------------------------------------------------

-- | Get a new fusion result, i.e., for when entering a new scope,
--   e.g., a new lambda or a new loop.
mkFreshFusionRes :: FusedRes
mkFreshFusionRes =
    FusedRes { rsucc     = False,   outArr = HM.empty, inpArr  = HM.empty,
               unfusable = HS.empty, kernels = HM.empty }

unionFusionRes :: FusedRes -> FusedRes -> FusedRes
unionFusionRes res1 res2 =
    FusedRes  (rsucc     res1       ||      rsucc     res2)
              (outArr    res1    `HM.union`  outArr    res2)
              (HM.unionWith HS.union (inpArr res1) (inpArr res2) )
              (unfusable res1    `HS.union`  unfusable res2)
              (kernels   res1    `HM.union`  kernels   res2)

mergeFusionRes :: FusedRes -> FusedRes -> FusionGM FusedRes
mergeFusionRes res1 res2 = do
    let ufus_mres = unfusable res1 `HS.union` unfusable res2
    inp_both     <- expandSoacInpArr $ HM.keys $ inpArr res1 `HM.intersection` inpArr res2
    let m_unfus   = foldl (flip HS.insert) ufus_mres inp_both
    return $ FusedRes  (rsucc     res1       ||      rsucc     res2)
                       (outArr    res1    `HM.union`  outArr    res2)
                       (HM.unionWith HS.union (inpArr res1) (inpArr res2) )
                       m_unfus
                       (kernels   res1    `HM.union`  kernels   res2)


-- | The expression arguments are supposed to be array-type exps.
--   Returns a tuple, in which the arrays that are vars are in the
--   first element of the tuple, and the one which are indexed or
--   transposes should be in the second.
--
--   E.g., for expression `mapT(f, a, b[i])', the result should be
--   `([a],[b])'
getIdentArr :: [SOAC.Input] -> ([Ident], [Ident])
getIdentArr = foldl comb ([],[])
  where comb (vs, os) (SOAC.Var idd) =
          (idd:vs, os)
        comb (vs, os) (SOAC.Transpose _ _ _ inp) =
          let (ks1, ks2) = getIdentArr [inp]
          in (vs, ks1++ks2++os)
        comb (vs, os) (SOAC.Index _ idd _ _) =
          (vs, idd:os)
        comb (vs, os) (SOAC.Iota _) = (vs, os)

cleanFusionResult :: FusedRes -> FusedRes
cleanFusionResult fres =
    let newks = HM.filter (not . null . fusedVars)      (kernels fres)
        newoa = HM.filter (`HM.member` newks)            (outArr  fres)
        newia = HM.map    (HS.filter (`HM.member` newks)) (inpArr fres)
    in fres { outArr = newoa, inpArr = newia, kernels = newks }

--------------
--- Errors ---
--------------

errorIllegal :: String -> SrcLoc -> FusionGM FusedRes
errorIllegal soac_name pos =
    badFusionGM $ EnablingOptError pos
                  ("In Fusion.hs, soac "++soac_name++" appears illegally in pgm!")

errorIllegalFus :: String -> SrcLoc -> FusionGM Exp
errorIllegalFus soac_name pos =
    badFusionGM $ EnablingOptError pos
                  ("In Fusion.hs, soac "++soac_name++" appears illegally in pgm!")

--------------------------------------------
--------------------------------------------
--- FUSING 2 COMPATIBLE SOACs:           ---
--------------------------------------------
--------------------------------------------

isCompatibleKer :: ([Ident], SOAC) -> FusedKer -> Bool
isCompatibleKer (outIds, SOAC.MapT {}) ker =
  isOmapKer ker &&
  all (`elem` inputs ker) (map SOAC.Var outIds)
isCompatibleKer (outIds, SOAC.FilterT {}) ker =
  let soac = fsoac ker
      ok = case soac of
            SOAC.ReduceT {} -> True
            SOAC.RedomapT{} -> True
            SOAC.FilterT {} -> True
            SOAC.MapT    {} -> False
            SOAC.ScanT   {} -> False
  in if not ok
     then False
     else -- check that the input-array set of consumer is included
          -- in the output-array set of producer.  That is, a
          -- filter-producer can only be fused if the consumer
          -- accepts input from no other source.
          case mapM SOAC.inputArray $ SOAC.inputs soac of
            Nothing       -> False
            Just inputIds -> all (`elem` outIds) inputIds
isCompatibleKer _ _ = False

isOmapKer :: FusedKer -> Bool
isOmapKer ker =
  case fsoac ker of
    SOAC.ReduceT {} -> True
    SOAC.RedomapT{} -> True
    SOAC.MapT    {} -> True
    _               -> False
