-- | Facilities for composing SOAC functions.  Mostly intended for use
-- by the fusion module, but factored into a separate module for ease
-- of testing, debugging and development.  Of course, there is nothing
-- preventing you from using the exported functions whereever you
-- want.
--
-- Important: this module is \"dumb\" in the sense that it does not
-- check the validity of its inputs, and does not have any
-- functionality for massaging SOACs to be fusable.  It is assumed
-- that the given SOACs are immediately compatible.
--
-- The module will, however, remove duplicate inputs after fusion.
module Futhark.Optimise.Fusion.Composing
  ( fuseMaps
  , fuseFilters
  , fuseFilterIntoFold
  , Input(..)
  )
  where

import Data.List
import qualified Data.HashMap.Lazy as HM
import qualified Data.Map as M
import Data.Maybe

import qualified Futhark.Analysis.HORepresentation.SOAC as SOAC

import Futhark.Representation.AST
import Futhark.Binder
  (Bindable(..), insertBinding, insertBindings, mkBody, mkLet')
import Futhark.Tools (mapResult)

-- | Something that can be used as a SOAC input.  As far as this
-- module is concerned, this means supporting just a single operation.
class (Ord a, Eq a) => Input a where
  -- | Check whether an arbitrary input corresponds to a plain
  -- variable input.  If so, return that variable.
  isVarInput :: a -> Maybe Ident

instance Input SOAC.Input where
  isVarInput = SOAC.isVarInput

instance (Show a, Ord a, Input inp) => Input (a, inp) where
  isVarInput = isVarInput . snd

-- | @fuseMaps lam1 inp1 out1 lam2 inp2@ fuses the function @lam1@ into
-- @lam2@.  Both functions must be mapping functions, although @lam2@
-- may have leading reduction parameters.  @inp1@ and @inp2@ are the
-- array inputs to the SOACs containing @lam1@ and @lam2@
-- respectively.  @out1@ are the identifiers to which the output of
-- the SOAC containing @lam1@ is bound.  It is nonsensical to call
-- this function unless the intersection of @out1@ and @inp2@ is
-- non-empty.
--
-- If @lam2@ accepts more parameters than there are elements in
-- @inp2@, it is assumed that the surplus (which are positioned at the
-- beginning of the parameter list) are reduction (accumulator)
-- parameters, that do not correspond to array elements, and they are
-- thus not modified.
--
-- The result is the fused function, and a list of the array inputs
-- expected by the SOAC containing the fused function.
fuseMaps :: (Input input, Bindable lore) =>
            Lambda lore -- ^ Function of SOAC to be fused.
         -> [input] -- ^ Input of SOAC to be fused.
         -> [(Ident,Ident)] -- ^ Output of SOAC to be fused.  The
                            -- first identifier is the name of the
                            -- actual output, where the second output
                            -- is an identifier that can be used to
                            -- bind a single element of that output.
         -> Lambda lore -- ^ Function to be fused with.
         -> [input] -- ^ Input of SOAC to be fused with.
         -> (Lambda lore, [input]) -- ^ The fused lambda and the inputs of
                              -- the resulting SOAC.
fuseMaps lam1 inp1 out1 lam2 inp2 = (lam2', HM.elems inputmap)
  where lam2' =
          lam2 { lambdaParams = lam2redparams ++ HM.keys inputmap
               , lambdaBody =
                 let bnds res = [ mkLet' [p] $ PrimOp $ SubExp e
                                | (p,e) <- zip pat $ resultSubExps res]
                     bindLambda res =
                       bnds res `insertBindings` makeCopiesInner (lambdaBody lam2)
                 in makeCopies $ mapResult bindLambda $ lambdaBody lam1
               }

        (lam2redparams, pat, inputmap, makeCopies, makeCopiesInner) =
          fuseInputs lam1 inp1 out1 lam2 inp2

-- | Similar to 'fuseMaps', although the two functions must be
-- predicates returning @{bool}@.  Returns a new predicate function.
fuseFilters :: (Input input, Bindable lore) =>
               Lambda lore -- ^ Function of SOAC to be fused.
            -> [input] -- ^ Input of SOAC to be fused.
            -> [(Ident,Ident)] -- ^ Output of SOAC to be fused.
            -> Lambda lore -- ^ Function to be fused with.
            -> [input] -- ^ Input of SOAC to be fused with.
            -> VName -- ^ A fresh name (used internally).
            -> (Lambda lore, [input]) -- ^ The fused lambda and the inputs of the resulting SOAC.
fuseFilters lam1 inp1 out1 lam2 inp2 vname =
  fuseFilterInto lam1 inp1 out1 lam2 inp2 [vname] false
  where false = mkBody [] $ Result [constant False]

-- | Similar to 'fuseFilters', except the second function does not
-- have to return @{bool}@, but must be a folding function taking at
-- least one reduction parameter (that is, the number of parameters
-- accepted by the function must be at least one greater than its
-- number of inputs).  If @f1@ is the to-be-fused function, and @f2@
-- is the function to be fused with, the resulting function will be of
-- roughly following form:
--
-- @
-- fn (acc, args) => if f1(args)
--                   then f2(acc,args)
--                   else acc
-- @
fuseFilterIntoFold :: (Input input, Bindable lore) =>
                      Lambda lore -- ^ Function of SOAC to be fused.
                   -> [input] -- ^ Input of SOAC to be fused.
                   -> [(Ident,Ident)] -- ^ Output of SOAC to be fused.
                   -> Lambda lore -- ^ Function to be fused with.
                   -> [input] -- ^ Input of SOAC to be fused with.
                   -> [VName] -- ^ A fresh name (used internally).
                   -> (Lambda lore, [input]) -- ^ The fused lambda and the inputs of the resulting SOAC.
fuseFilterIntoFold lam1 inp1 out1 lam2 inp2 vnames =
  fuseFilterInto lam1 inp1 out1 lam2 inp2 vnames identity
  where identity = mkBody [] $ Result (map Var lam2redparams)
        lam2redparams = take (length (lambdaParams lam2) - length inp2) $
                        lambdaParams lam2

fuseFilterInto :: (Input input, Bindable lore) =>
                  Lambda lore -> [input] -> [(Ident,Ident)]
               -> Lambda lore -> [input]
               -> [VName] -> Body lore
               -> (Lambda lore, [input])
fuseFilterInto lam1 inp1 out1 lam2 inp2 vnames falsebranch = (lam2', HM.elems inputmap)
  where lam2' =
          lam2 { lambdaParams = lam2redparams ++ HM.keys inputmap
               , lambdaBody = makeCopies bindins
               }
        restype = lambdaReturnType lam2
        residents = [ Ident vname t | (vname, t) <- zip vnames restype ]
        branch = flip mapResult (lambdaBody lam1) $ \res ->
                 let [e] = resultSubExps res -- XXX
                     tbranch = makeCopiesInner $ lambdaBody lam2
                     ts = bodyExtType tbranch `generaliseExtTypes`
                          bodyExtType falsebranch
                 in mkBody [mkLet' residents $
                            If e tbranch falsebranch ts] $
                 Result (map Var residents)
        lam1tuple = [ mkLet' [v] $ PrimOp $ SubExp $ Var p
                    | (v,p) <- zip pat $ lambdaParams lam1 ]
        bindins = lam1tuple `insertBindings` branch

        (lam2redparams, pat, inputmap, makeCopies, makeCopiesInner) =
          fuseInputs lam1 inp1 out1 lam2 inp2

fuseInputs :: (Input input, Bindable lore) =>
              Lambda lore -> [input] -> [(Ident,Ident)]
           -> Lambda lore -> [input]
           -> ([Param],
               [Ident],
               HM.HashMap Param input,
               Body lore -> Body lore, Body lore -> Body lore)
fuseInputs lam1 inp1 out1 lam2 inp2 =
  (lam2redparams, outbnds, inputmap, makeCopies, makeCopiesInner)
  where (lam2redparams, lam2arrparams) =
          splitAt (length (lambdaParams lam2) - length inp2) $ lambdaParams lam2
        lam1inputmap = HM.fromList $ zip (lambdaParams lam1) inp1
        lam2inputmap = HM.fromList $ zip lam2arrparams            inp2
        (lam2inputmap', makeCopiesInner) = removeDuplicateInputs lam2inputmap
        originputmap = lam1inputmap `HM.union` lam2inputmap'
        outins = uncurry (outParams $ map fst out1) $
                 unzip $ HM.toList lam2inputmap'
        outbnds = filterOutParams out1 outins
        (inputmap, makeCopies) =
          removeDuplicateInputs $ originputmap `HM.difference` outins

outParams :: Input input =>
             [Ident] -> [Param] -> [input]
          -> HM.HashMap Param input
outParams out1 lam2arrparams inp2 =
  HM.fromList $ mapMaybe isOutParam $ zip lam2arrparams inp2
  where isOutParam (p, inp)
          | Just a <- isVarInput inp,
            a `elem` out1 = Just (p, inp)
        isOutParam _      = Nothing

filterOutParams :: Input input =>
                   [(Ident,Ident)]
                -> HM.HashMap Param input
                -> [Ident]
filterOutParams out1 outins =
  snd $ mapAccumL checkUsed outUsage out1
  where outUsage = HM.foldlWithKey' add M.empty outins
          where add m p inp =
                  case isVarInput inp of
                    Just v  -> M.insertWith (++) v [p] m
                    Nothing -> m

        checkUsed m (a,ra) =
          case M.lookup a m of
            Just (p:ps) -> (M.insert a ps m, p)
            _           -> (m, ra)


removeDuplicateInputs :: (Input input, Bindable lore) =>
                         HM.HashMap Param input
                      -> (HM.HashMap Param input, Body lore -> Body lore)
removeDuplicateInputs = fst . HM.foldlWithKey' comb ((HM.empty, id), M.empty)
  where comb ((parmap, inner), arrmap) par arr =
          case M.lookup arr arrmap of
            Nothing -> ((HM.insert par arr parmap, inner),
                        M.insert arr par arrmap)
            Just par' -> ((parmap, inner . forward par par'),
                          arrmap)
        forward to from b =
          mkLet' [to] (PrimOp $ SubExp $ Var from)
          `insertBinding` b

{-

An example of how I tested this module:

I add this import:

import Futhark.Dev

-}

{-
And now I can have top-level bindings like the following, that explicitly call fuseMaps:

(test1fun, test1ins) = fuseMaps lam1 lam1in out lam2 lam2in
  where lam1in = [SOAC.varInput $ tident "[int] arr_x", SOAC.varInput $ tident "[int] arr_z"]
        lam1 = lambdaToFunction $ lambda "fn {int, int} (int x, int z_b) => {x + z_b, x - z_b}"
        outarr = tident "[int] arr_y"
        outarr2 = tident "[int] arr_unused"
        out  = [outarr2, outarr]
        lam2in = [Var outarr, Var $ tident "[int] arr_z"]
        lam2 = lambdaToFunction $ lambda "fn {int} (int red, int y, int z) => {red + y + z}"


(test2fun, test2ins) = fuseFilterIntoFold lam1 lam1in out lam2 lam2in (name "check")
  where lam1in = [SOAC.varInput $ tident "[int] arr_x", SOAC.varInput $ tident "[int] arr_v"]
        lam1 = lambda "fn {bool} (int x, int v) => x+v < 0"
        outarr = tident "[int] arr_y"
        outarr2 = tident "[int] arr_unused"
        out  = [outarr, outarr2]
        lam2in = [Var outarr]
        lam2 = lambda "fn {int} (int red, int y) => {red + y}"

(test3fun, test3ins) = fuseFilterIntoFold lam1 lam1in out lam2 lam2in (name "check")
  where lam1in = [expr "iota(30)", expr "replicate(30, 1)"]
        lam1 = lambda "fn {bool} (int i, int j) => {i+j < 0}"
        outarr = tident "[int] arr_p"
        outarr2 = tident "[int] arr_unused"
        out  = [outarr, outarr2]
        lam2in = [SOAC.varInput outarr]
        lam2 = lambda "fn {int} (int x, int p) => {x ^ p}"

I can inspect these values directly in GHCi.

The point is to demonstrate that by factoring functionality out of the
huge monad in the fusion module, we get something that's much easier
to work with interactively.

-}
