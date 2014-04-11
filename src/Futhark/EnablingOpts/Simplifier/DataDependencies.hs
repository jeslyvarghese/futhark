module Futhark.EnablingOpts.Simplifier.DataDependencies
  ( dataDependencies
  )
  where

import Data.Maybe

import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS

import Futhark.InternalRep

dataDependencies :: Body -> HM.HashMap VName (HS.HashSet VName)
dataDependencies = dataDependencies' HM.empty
  where dataDependencies' deps = foldl grow deps . bodyBindings
        grow deps (Let pat (If c tb fb _ _)) =
          let tdeps = dataDependencies' deps tb
              fdeps = dataDependencies' deps fb
              cdeps = depsOf c deps
              comb (v, tres, fres) =
                (identName v, HS.unions [cdeps, depsOf tres tdeps, depsOf fres fdeps])
              branchdeps =
                HM.fromList $ map comb $ zip3 pat (resultSubExps $ bodyResult tb)
                                                  (resultSubExps $ bodyResult fb)
          in branchdeps `HM.union` deps

        grow deps (Let pat (DoLoop _ _ bound body _)) =
          let bodydeps = dataDependencies' deps body
              bounddeps = depsOf bound deps
              comb v e =
                (identName v, HS.unions [bounddeps, depsOf e bodydeps])
          in HM.fromList $ zipWith comb pat $ resultSubExps $ bodyResult body

        grow deps (Let pat e) =
          let free = freeNamesInExp e
              freeDeps = HS.unions $ free : map (`nameDeps` deps) (HS.toList free)
          in HM.fromList [ (identName v, freeDeps) | v <- pat ] `HM.union` deps

        nameDeps name deps = fromMaybe HS.empty $ HM.lookup name deps

        depsOf (Constant _ _) _ = HS.empty
        depsOf (Var v) deps     = nameDeps (identName v) deps
