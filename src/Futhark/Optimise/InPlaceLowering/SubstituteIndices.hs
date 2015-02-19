-- | This module exports facilities for transforming array accesses in
-- a list of 'Binding's (intended to be the bindings in a body).  The
-- idea is that you can state that some variable @x@ is in fact an
-- array indexing @v[i0,i1,...]@.
module Futhark.Optimise.InPlaceLowering.SubstituteIndices
       (
         substituteIndices
       , IndexSubstitution
       , IndexSubstitutions
       ) where

import Control.Applicative
import Control.Monad

import Futhark.Representation.AST
import Futhark.Tools
import Futhark.MonadFreshNames
import Futhark.Util

type IndexSubstitution = (Certificates, Ident, [SubExp])
type IndexSubstitutions = [(VName, IndexSubstitution)]

substituteIndices :: (MonadFreshNames m, Bindable lore) =>
                     IndexSubstitutions -> [Binding lore]
                  -> m ([IndexSubstitution], [Binding lore])
substituteIndices substs bnds = do
  (substs', bnds') <-
    runBinder'' $ substituteIndicesInBindings substs bnds
  return (map snd substs', bnds')

substituteIndicesInBindings :: MonadBinder m =>
                               IndexSubstitutions
                            -> [Binding (Lore m)]
                            -> m IndexSubstitutions
substituteIndicesInBindings = foldM substituteIndicesInBinding

substituteIndicesInBinding :: MonadBinder m =>
                              IndexSubstitutions
                           -> Binding (Lore m)
                           -> m IndexSubstitutions
substituteIndicesInBinding substs (Let pat lore e) = do
  (substs', pat') <- substituteIndicesInPattern substs pat
  e' <- mapExpM substitute e
  addBinding $ Let pat' lore e'
  return substs'
  where substitute = identityMapper { mapOnSubExp = substituteIndicesInSubExp substs
                                    , mapOnIdent  = substituteIndicesInIdent substs
                                    , mapOnBody   = substituteIndicesInBody substs
                                    }

substituteIndicesInPattern :: MonadBinder m =>
                              IndexSubstitutions
                           -> Pattern (Lore m)
                           -> m (IndexSubstitutions, Pattern (Lore m))
substituteIndicesInPattern substs pat = do
  (substs', patElems) <- mapAccumLM sub substs $ patternElements pat
  return (substs', Pattern patElems)
  where sub substs' (PatElem ident (BindInPlace cs src is) attr)
          | Just (cs2, src2, is2) <- lookup srcname substs =
            let ident' = ident { identType = identType src2 }
            in return (update srcname name (cs2, ident', is2) substs',
                       PatElem ident' (BindInPlace (cs++cs2) src2 (is2++is)) attr)
          where srcname = identName src
                name    = identName ident
        sub substs' patElem =
          return (substs', patElem)

substituteIndicesInSubExp :: MonadBinder m =>
                             IndexSubstitutions
                          -> SubExp
                          -> m SubExp
substituteIndicesInSubExp substs (Var v) = Var <$> substituteIndicesInIdent substs v
substituteIndicesInSubExp _      se      = return se


substituteIndicesInIdent :: MonadBinder m =>
                            IndexSubstitutions
                         -> Ident
                         -> m Ident
substituteIndicesInIdent substs v
  | Just (cs2, src2, is2) <- lookup (identName v) substs =
    letExp "idx" $ PrimOp $ Index cs2 src2 is2
  | otherwise =
    return v

substituteIndicesInBody :: MonadBinder m =>
                           IndexSubstitutions
                        -> Body (Lore m)
                        -> m (Body (Lore m))
substituteIndicesInBody substs body = do
  (substs', bnds) <-
    collectBindings $ substituteIndicesInBindings substs $ bodyBindings body
  ses <-
    mapM (substituteIndicesInSubExp substs') $ resultSubExps $ bodyResult body
  mkBodyM bnds $ Result ses

update :: VName -> VName -> IndexSubstitution -> IndexSubstitutions
       -> IndexSubstitutions
update needle name subst ((othername, othersubst) : substs)
  | needle == othername = (name, subst)           : substs
  | otherwise           = (othername, othersubst) : update needle name subst substs
update needle _    _ [] = error $ "Cannot find substitution for " ++ pretty needle
