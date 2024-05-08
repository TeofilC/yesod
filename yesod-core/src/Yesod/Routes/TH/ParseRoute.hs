{-# LANGUAGE TemplateHaskell #-}
module Yesod.Routes.TH.ParseRoute
    ( -- ** ParseRoute
      mkParseRouteInstance
    ) where

import Yesod.Routes.TH.Types
import Language.Haskell.TH.Syntax
import Data.Text (Text)
import Yesod.Routes.Class
import Yesod.Routes.TH.Dispatch
import Data.List (foldl')

mkParseRouteInstance :: Cxt -> Type -> [ResourceTree a] -> Q Dec
mkParseRouteInstance cxt typ ress = do
    let cls = mkDispatchClause
            MkDispatchSettings
                { mdsRunHandler = [|\_ _ x _ -> x|]
                , mds404 = [|error "mds404"|]
                , mds405 = [|error "mds405"|]
                , mdsGetPathInfo = [|fst|]
                , mdsMethod = [|error "mdsMethod"|]
                , mdsGetHandler = \_ _ -> [|error "mdsGetHandler"|]
                , mdsSetPathInfo = [|\p (_, q) -> (p, q)|]
                , mdsSubDispatcher = [|\_runHandler _getSub toMaster _env -> fmap toMaster . parseRoute|]
                , mdsUnwrapper = return
                }
            (map removeMethods ress)
    body <- [| $cls ()|]
    return $ instanceD cxt (ConT ''ParseRoute `AppT` typ)
        [ FunD 'parseRoute $ return $ Clause
            []
            (NormalB body)
            []
        ]
  where
    -- We do this in order to ski the unnecessary method parsing
    removeMethods (ResourceLeaf res) = ResourceLeaf $ removeMethodsLeaf res
    removeMethods (ResourceParent w x y z) = ResourceParent w x y $ map removeMethods z

    removeMethodsLeaf res = res { resourceDispatch = fixDispatch $ resourceDispatch res }

    fixDispatch (Methods x _) = Methods x []
    fixDispatch x = x

instanceD :: Cxt -> Type -> [Dec] -> Dec
instanceD = InstanceD Nothing
