{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

module Test.Syd.Yesod.Client where

import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.State
import qualified Control.Monad.State as State
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import qualified Data.Text as T
import Network.HTTP.Client as HTTP
import Network.HTTP.Types as HTTP
import Yesod.Core as Yesod

-- | A client environment to call a Yesod app.
data YesodClient site = YesodClient
  { -- | The site itself
    yesodClientSite :: !site,
    -- | The 'HTTP.Manager' to make the requests
    yesodClientManager :: !HTTP.Manager,
    -- | The port that the site is running on, using @warp@
    yesodClientSitePort :: !Int
  }

data YesodClientState site = YesodClientState
  { -- | The last request and response pair
    yesodClientStateLast :: !(Maybe (Request, Response LB.ByteString)),
    -- | The cookies to pass along
    yesodClientStateCookies :: !CookieJar
  }

initYesodClientState :: YesodClientState site
initYesodClientState =
  YesodClientState
    { yesodClientStateLast = Nothing,
      yesodClientStateCookies = createCookieJar []
    }

-- | A monad to call a Yesod app.
--
-- This has access to a 'YesodClient site'.
newtype YesodClientM site a = YesodClientM
  { unYesodClientM :: StateT (YesodClientState site) (ReaderT (YesodClient site) IO) a
  }
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadIO,
      MonadReader (YesodClient site),
      MonadState (YesodClientState site),
      MonadFail,
      MonadThrow
    )

-- | For backward compatibility
type YesodExample site a = YesodClientM site a

-- | Run a YesodClientM site using a YesodClient site
runYesodClientM :: YesodClient site -> YesodClientM site a -> IO a
runYesodClientM cenv (YesodClientM func) = runReaderT (evalStateT func initYesodClientState) cenv

-- | Get the most recently sent request.
getRequest :: YesodClientM site (Maybe Request)
getRequest = State.gets (fmap fst . yesodClientStateLast)

-- | Get the most recently received response.
getResponse :: YesodClientM site (Maybe (Response LB.ByteString))
getResponse = State.gets (fmap snd . yesodClientStateLast)

-- | Get the most recently sent request and the response to it.
getLast :: YesodClientM site (Maybe (Request, Response LB.ByteString))
getLast = State.gets yesodClientStateLast

-- | Get the 'Location' header of most recently received response.
getLocation :: ParseRoute site => YesodClientM site (Either Text (Route site))
getLocation = do
  mr <- getResponse
  case mr of
    Nothing -> return $ Left "getLocation called, but there was no previous response, so no Location header"
    Just r -> case lookup "Location" (responseHeaders r) of
      Nothing -> return $ Left "getLocation called, but the previous response has no Location header"
      Just h -> case parseRoute $ decodePath' h of
        Nothing -> return $ Left $ "getLocation called, but couldn’t parse it into a route: " <> T.pack (show h)
        Just l -> return $ Right l
  where
    decodePath' :: ByteString -> ([Text], [(Text, Text)])
    decodePath' b =
      let (ss, q) = decodePath $ extractPath b
       in (ss, map unJust $ queryToQueryText q)
    unJust (a, Just b) = (a, b)
    unJust (a, Nothing) = (a, mempty)
