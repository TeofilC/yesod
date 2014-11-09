{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{-|
Yesod.Test is a pragmatic framework for testing web applications built
using wai and persistent.

By pragmatic I may also mean 'dirty'. It's main goal is to encourage integration
and system testing of web applications by making everything /easy to test/.

Your tests are like browser sessions that keep track of cookies and the last
visited page. You can perform assertions on the content of HTML responses,
using css selectors to explore the document more easily.

You can also easily build requests using forms present in the current page.
This is very useful for testing web applications built in yesod for example,
were your forms may have field names generated by the framework or a randomly
generated '_nonce' field.

Your database is also directly available so you can use runDBRunner to set up
backend pre-conditions, or to assert that your session is having the desired effect.

-}

module Yesod.Test
    ( -- * Declaring and running your test suite
      yesodSpec
    , YesodSpec
    , yesodSpecWithSiteGenerator
    , yesodSpecApp
    , YesodExample
    , YesodExampleData(..)
    , YesodSpecTree (..)
    , ydescribe
    , yit

    -- * Making requests
    -- | To make a request you need to point to an url and pass in some parameters.
    --
    -- To build your parameters you will use the RequestBuilder monad that lets you
    -- add values, add files, lookup fields by label and find the current
    -- nonce value and add it to your request too.
    --
    , get
    , post
    , postBody
    , request
    , addRequestHeader
    , setMethod
    , addPostParam
    , addGetParam
    , addFile
    , setRequestBody
    , RequestBuilder
    , setUrl

    -- | Yesod can auto generate field ids, so you are never sure what
    -- the argument name should be for each one of your args when constructing
    -- your requests. What you do know is the /label/ of the field.
    -- These functions let you add parameters to your request based
    -- on currently displayed label names.
    , byLabel
    , fileByLabel

    -- | Does the current form have a _nonce? Use any of these to add it to your
    -- request parameters.
    , addNonce
    , addNonce_

    -- * Assertions
    , assertEqual
    , assertHeader
    , assertNoHeader
    , statusIs
    , bodyEquals
    , bodyContains
    , htmlAllContain
    , htmlAnyContain
    , htmlNoneContain
    , htmlCount

    -- * Grab information
    , getTestYesod
    , getResponse

    -- * Debug output
    , printBody
    , printMatches

    -- * Utils for building your own assertions
    -- | Please consider generalizing and contributing the assertions you write.
    , htmlQuery
    , parseHTML
    , withResponse
    ) where

import qualified Test.Hspec as Hspec
import qualified Test.Hspec.Core as Hspec
import qualified Data.List as DL
import qualified Data.ByteString.Char8 as BS8
import Data.ByteString (ByteString)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString.Lazy.Char8 as BSL8
import qualified Test.HUnit as HUnit
import qualified Network.HTTP.Types as H
import qualified Network.Socket.Internal as Sock
import Data.CaseInsensitive (CI)
import Network.Wai
import Network.Wai.Test hiding (assertHeader, assertNoHeader, request)
import qualified Control.Monad.Trans.State as ST
import Control.Monad.IO.Class
import System.IO
import Yesod.Test.TransversingCSS
import Yesod.Core
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Encoding (encodeUtf8, decodeUtf8)
import Text.XML.Cursor hiding (element)
import qualified Text.XML.Cursor as C
import qualified Text.HTML.DOM as HD
import Control.Monad.Trans.Writer
import qualified Data.Map as M
import qualified Web.Cookie as Cookie
import qualified Blaze.ByteString.Builder as Builder
import Data.Time.Clock (getCurrentTime)

-- | The state used in a single test case defined using 'yit'
--
-- Since 1.2.4
data YesodExampleData site = YesodExampleData
    { yedApp :: !Application
    , yedSite :: !site
    , yedCookies :: !Cookies
    , yedResponse :: !(Maybe SResponse)
    }

-- | A single test case, to be run with 'yit'.
--
-- Since 1.2.0
type YesodExample site = ST.StateT (YesodExampleData site) IO

-- | Mapping from cookie name to value.
--
-- Since 1.2.0
type Cookies = M.Map ByteString Cookie.SetCookie

-- | Corresponds to hspec\'s 'Spec'.
--
-- Since 1.2.0
type YesodSpec site = Writer [YesodSpecTree site] ()

-- | Internal data structure, corresponding to hspec\'s 'YesodSpecTree'.
--
-- Since 1.2.0
data YesodSpecTree site
    = YesodSpecGroup String [YesodSpecTree site]
    | YesodSpecItem String (YesodExample site ())

-- | Get the foundation value used for the current test.
--
-- Since 1.2.0
getTestYesod :: YesodExample site site
getTestYesod = fmap yedSite ST.get

-- | Get the most recently provided response value, if available.
--
-- Since 1.2.0
getResponse :: YesodExample site (Maybe SResponse)
getResponse = fmap yedResponse ST.get

data RequestBuilderData site = RequestBuilderData
    { rbdPostData :: RBDPostData
    , rbdResponse :: (Maybe SResponse)
    , rbdMethod :: H.Method
    , rbdSite :: site
    , rbdPath :: [T.Text]
    , rbdGets :: H.Query
    , rbdHeaders :: H.RequestHeaders
    }

data RBDPostData = MultipleItemsPostData [RequestPart]
                 | BinaryPostData BSL8.ByteString

-- | Request parts let us discern regular key/values from files sent in the request.
data RequestPart
  = ReqKvPart T.Text T.Text
  | ReqFilePart T.Text FilePath BSL8.ByteString T.Text

-- | The RequestBuilder state monad constructs an url encoded string of arguments
-- to send with your requests. Some of the functions that run on it use the current
-- response to analyze the forms that the server is expecting to receive.
type RequestBuilder site = ST.StateT (RequestBuilderData site) IO

-- | Start describing a Tests suite keeping cookies and a reference to the tested 'Application'
-- and 'ConnectionPool'
ydescribe :: String -> YesodSpec site -> YesodSpec site
ydescribe label yspecs = tell [YesodSpecGroup label $ execWriter yspecs]

yesodSpec :: YesodDispatch site
          => site
          -> YesodSpec site
          -> Hspec.Spec
yesodSpec site yspecs =
    Hspec.fromSpecList $ map unYesod $ execWriter yspecs
  where
    unYesod (YesodSpecGroup x y) = Hspec.specGroup x $ map unYesod y
    unYesod (YesodSpecItem x y) = Hspec.specItem x $ do
        app <- toWaiAppPlain site
        ST.evalStateT y YesodExampleData
            { yedApp = app
            , yedSite = site
            , yedCookies = M.empty
            , yedResponse = Nothing
            }

-- | Same as yesodSpec, but instead of taking already built site it
-- takes an action which produces site for each test.
yesodSpecWithSiteGenerator :: YesodDispatch site
                           => IO site
                           -> YesodSpec site
                           -> Hspec.Spec
yesodSpecWithSiteGenerator getSiteAction yspecs =
    Hspec.fromSpecList $ map (unYesod getSiteAction) $ execWriter yspecs
    where
      unYesod getSiteAction' (YesodSpecGroup x y) = Hspec.specGroup x $ map (unYesod getSiteAction') y
      unYesod getSiteAction' (YesodSpecItem x y) = Hspec.specItem x $ do
        site <- getSiteAction'
        app <- toWaiAppPlain site
        ST.evalStateT y YesodExampleData
            { yedApp = app
            , yedSite = site
            , yedCookies = M.empty
            , yedResponse = Nothing
            }

-- | Same as yesodSpec, but instead of taking a site it
-- takes an action which produces the 'Application' for each test.
-- This lets you use your middleware from makeApplication
yesodSpecApp :: YesodDispatch site
             => site
             -> IO Application
             -> YesodSpec site
             -> Hspec.Spec
yesodSpecApp site getApp yspecs =
    Hspec.fromSpecList $ map unYesod $ execWriter yspecs
  where
    unYesod (YesodSpecGroup x y) = Hspec.specGroup x $ map unYesod y
    unYesod (YesodSpecItem x y) = Hspec.specItem x $ do
        app <- getApp
        ST.evalStateT y YesodExampleData
            { yedApp = app
            , yedSite = site
            , yedCookies = M.empty
            , yedResponse = Nothing
            }

-- | Describe a single test that keeps cookies, and a reference to the last response.
yit :: String -> YesodExample site () -> YesodSpec site
yit label example = tell [YesodSpecItem label example]

-- Performs a given action using the last response. Use this to create
-- response-level assertions
withResponse' :: MonadIO m
              => (state -> Maybe SResponse)
              -> (SResponse -> ST.StateT state m a)
              -> ST.StateT state m a
withResponse' getter f = maybe err f . getter =<< ST.get
 where err = failure "There was no response, you should make a request"

-- | Performs a given action using the last response. Use this to create
-- response-level assertions
withResponse :: (SResponse -> YesodExample site a) -> YesodExample site a
withResponse = withResponse' yedResponse

-- | Use HXT to parse a value from an html tag.
-- Check for usage examples in this module's source.
parseHTML :: HtmlLBS -> Cursor
parseHTML html = fromDocument $ HD.parseLBS html

-- | Query the last response using css selectors, returns a list of matched fragments
htmlQuery' :: MonadIO m
           => (state -> Maybe SResponse)
           -> Query
           -> ST.StateT state m [HtmlLBS]
htmlQuery' getter query = withResponse' getter $ \ res ->
  case findBySelector (simpleBody res) query of
    Left err -> failure $ query <> " did not parse: " <> T.pack (show err)
    Right matches -> return $ map (encodeUtf8 . TL.pack) matches

-- | Query the last response using css selectors, returns a list of matched fragments
htmlQuery :: Query -> YesodExample site [HtmlLBS]
htmlQuery = htmlQuery' yedResponse

-- | Asserts that the two given values are equal.
assertEqual :: (Eq a) => String -> a -> a -> YesodExample site ()
assertEqual msg a b = liftIO $ HUnit.assertBool msg (a == b)

-- | Assert the last response status is as expected.
statusIs :: Int -> YesodExample site ()
statusIs number = withResponse $ \ SResponse { simpleStatus = s } ->
  liftIO $ flip HUnit.assertBool (H.statusCode s == number) $ concat
    [ "Expected status was ", show number
    , " but received status was ", show $ H.statusCode s
    ]

-- | Assert the given header key/value pair was returned.
assertHeader :: CI BS8.ByteString -> BS8.ByteString -> YesodExample site ()
assertHeader header value = withResponse $ \ SResponse { simpleHeaders = h } ->
  case lookup header h of
    Nothing -> failure $ T.pack $ concat
        [ "Expected header "
        , show header
        , " to be "
        , show value
        , ", but it was not present"
        ]
    Just value' -> liftIO $ flip HUnit.assertBool (value == value') $ concat
        [ "Expected header "
        , show header
        , " to be "
        , show value
        , ", but received "
        , show value'
        ]

-- | Assert the given header was not included in the response.
assertNoHeader :: CI BS8.ByteString -> YesodExample site ()
assertNoHeader header = withResponse $ \ SResponse { simpleHeaders = h } ->
  case lookup header h of
    Nothing -> return ()
    Just s  -> failure $ T.pack $ concat
        [ "Unexpected header "
        , show header
        , " containing "
        , show s
        ]

-- | Assert the last response is exactly equal to the given text. This is
-- useful for testing API responses.
bodyEquals :: String -> YesodExample site ()
bodyEquals text = withResponse $ \ res ->
  liftIO $ HUnit.assertBool ("Expected body to equal " ++ text) $
    (simpleBody res) == encodeUtf8 (TL.pack text)

-- | Assert the last response has the given text. The check is performed using the response
-- body in full text form.
bodyContains :: String -> YesodExample site ()
bodyContains text = withResponse $ \ res ->
  liftIO $ HUnit.assertBool ("Expected body to contain " ++ text) $
    (simpleBody res) `contains` text

contains :: BSL8.ByteString -> String -> Bool
contains a b = DL.isInfixOf b (TL.unpack $ decodeUtf8 a)

-- | Queries the html using a css selector, and all matched elements must contain
-- the given string.
htmlAllContain :: Query -> String -> YesodExample site ()
htmlAllContain query search = do
  matches <- htmlQuery query
  case matches of
    [] -> failure $ "Nothing matched css query: " <> query
    _ -> liftIO $ HUnit.assertBool ("Not all "++T.unpack query++" contain "++search) $
          DL.all (DL.isInfixOf search) (map (TL.unpack . decodeUtf8) matches)

-- | Queries the html using a css selector, and passes if any matched
-- element contains the given string.
--
-- Since 0.3.5
htmlAnyContain :: Query -> String -> YesodExample site ()
htmlAnyContain query search = do
  matches <- htmlQuery query
  case matches of
    [] -> failure $ "Nothing matched css query: " <> query
    _ -> liftIO $ HUnit.assertBool ("None of "++T.unpack query++" contain "++search) $
          DL.any (DL.isInfixOf search) (map (TL.unpack . decodeUtf8) matches)

-- | Queries the html using a css selector, and fails if any matched
-- element contains the given string (in other words, it is the logical
-- inverse of htmlAnyContains).
--
-- Since 1.2.2
htmlNoneContain :: Query -> String -> YesodExample site ()
htmlNoneContain query search = do
  matches <- htmlQuery query
  case DL.filter (DL.isInfixOf search) (map (TL.unpack . decodeUtf8) matches) of
    [] -> return ()
    found -> failure $ "Found " <> T.pack (show $ length found) <>
                " instances of " <> T.pack search <> " in " <> query <> " elements"

-- | Performs a css query on the last response and asserts the matched elements
-- are as many as expected.
htmlCount :: Query -> Int -> YesodExample site ()
htmlCount query count = do
  matches <- fmap DL.length $ htmlQuery query
  liftIO $ flip HUnit.assertBool (matches == count)
    ("Expected "++(show count)++" elements to match "++T.unpack query++", found "++(show matches))

-- | Outputs the last response body to stderr (So it doesn't get captured by HSpec)
printBody :: YesodExample site ()
printBody = withResponse $ \ SResponse { simpleBody = b } ->
  liftIO $ BSL8.hPutStrLn stderr b

-- | Performs a CSS query and print the matches to stderr.
printMatches :: Query -> YesodExample site ()
printMatches query = do
  matches <- htmlQuery query
  liftIO $ hPutStrLn stderr $ show matches

-- | Add a parameter with the given name and value.
addPostParam :: T.Text -> T.Text -> RequestBuilder site ()
addPostParam name value =
  ST.modify $ \rbd -> rbd { rbdPostData = (addPostData (rbdPostData rbd)) }
  where addPostData (BinaryPostData _) = error "Trying to add post param to binary content."
        addPostData (MultipleItemsPostData posts) =
          MultipleItemsPostData $ ReqKvPart name value : posts

addGetParam :: T.Text -> T.Text -> RequestBuilder site ()
addGetParam name value = ST.modify $ \rbd -> rbd
    { rbdGets = (TE.encodeUtf8 name, Just $ TE.encodeUtf8 value)
              : rbdGets rbd
    }

-- | Add a file to be posted with the current request
--
-- Adding a file will automatically change your request content-type to be multipart/form-data
addFile :: T.Text -> FilePath -> T.Text -> RequestBuilder site ()
addFile name path mimetype = do
  contents <- liftIO $ BSL8.readFile path
  ST.modify $ \rbd -> rbd { rbdPostData = (addPostData (rbdPostData rbd) contents) }
    where addPostData (BinaryPostData _) _ = error "Trying to add file after setting binary content."
          addPostData (MultipleItemsPostData posts) contents =
            MultipleItemsPostData $ ReqFilePart name path contents mimetype : posts

-- This looks up the name of a field based on the contents of the label pointing to it.
nameFromLabel :: T.Text -> RequestBuilder site T.Text
nameFromLabel label = do
  mres <- fmap rbdResponse ST.get
  res <-
    case mres of
      Nothing -> failure "nameFromLabel: No response available"
      Just res -> return res
  let
    body = simpleBody res
    mlabel = parseHTML body
                $// C.element "label"
                >=> contentContains label
    mfor = mlabel >>= attribute "for"

    contentContains x c
        | x `T.isInfixOf` T.concat (c $// content) = [c]
        | otherwise = []

  case mfor of
    for:[] -> do
      let mname = parseHTML body
                    $// attributeIs "id" for
                    >=> attribute "name"
      case mname of
        "":_ -> failure $ T.concat
            [ "Label "
            , label
            , " resolved to id "
            , for
            , " which was not found. "
            ]
        name:_ -> return name
        [] -> failure $ "No input with id " <> for
    [] ->
      case filter (/= "") $ mlabel >>= (child >=> C.element "input" >=> attribute "name") of
        [] -> failure $ "No label contained: " <> label
        name:_ -> return name
    _ -> failure $ "More than one label contained " <> label

(<>) :: T.Text -> T.Text -> T.Text
(<>) = T.append

byLabel :: T.Text -> T.Text -> RequestBuilder site ()
byLabel label value = do
  name <- nameFromLabel label
  addPostParam name value

fileByLabel :: T.Text -> FilePath -> T.Text -> RequestBuilder site ()
fileByLabel label path mime = do
  name <- nameFromLabel label
  addFile name path mime

-- | Lookup a _nonce form field and add it's value to the params.
-- Receives a CSS selector that should resolve to the form element containing the nonce.
addNonce_ :: Query -> RequestBuilder site ()
addNonce_ scope = do
  matches <- htmlQuery' rbdResponse $ scope <> "input[name=_token][type=hidden][value]"
  case matches of
    [] -> failure $ "No nonce found in the current page"
    element:[] -> addPostParam "_token" $ head $ attribute "value" $ parseHTML element
    _ -> failure $ "More than one nonce found in the page"

-- | For responses that display a single form, just lookup the only nonce available.
addNonce :: RequestBuilder site ()
addNonce = addNonce_ ""

-- | Perform a POST request to url
post :: (Yesod site, RedirectUrl site url)
     => url
     -> YesodExample site ()
post url = request $ do
  setMethod "POST"
  setUrl url

-- | Perform a POST request to url with sending a body into it.
postBody :: (Yesod site, RedirectUrl site url)
         => url
         -> BSL8.ByteString
         -> YesodExample site ()
postBody url body = request $ do
  setMethod "POST"
  setUrl url
  setRequestBody body

-- | Perform a GET request to url, using params
get :: (Yesod site, RedirectUrl site url)
    => url
    -> YesodExample site ()
get url = request $ do
    setMethod "GET"
    setUrl url

setMethod :: H.Method -> RequestBuilder site ()
setMethod m = ST.modify $ \rbd -> rbd { rbdMethod = m }

setUrl :: (Yesod site, RedirectUrl site url)
       => url
       -> RequestBuilder site ()
setUrl url' = do
    site <- fmap rbdSite ST.get
    eurl <- runFakeHandler
        M.empty
        (const $ error "Yesod.Test: No logger available")
        site
        (toTextUrl url')
    url <- either (error . show) return eurl
    let (urlPath, urlQuery) = T.break (== '?') url
    ST.modify $ \rbd -> rbd
        { rbdPath =
            case DL.filter (/="") $ H.decodePathSegments $ TE.encodeUtf8 urlPath of
                ("http:":_:rest) -> rest
                ("https:":_:rest) -> rest
                x -> x
        , rbdGets = rbdGets rbd ++ H.parseQuery (TE.encodeUtf8 urlQuery)
        }

-- | Simple way to set HTTP request body
setRequestBody :: (Yesod site)
               => BSL8.ByteString
               -> RequestBuilder site ()
setRequestBody body = ST.modify $ \rbd -> rbd { rbdPostData = BinaryPostData body }

addRequestHeader :: H.Header -> RequestBuilder site ()
addRequestHeader header = ST.modify $ \rbd -> rbd
    { rbdHeaders = header : rbdHeaders rbd
    }

-- | General interface to performing requests, allowing you to add extra
-- headers as well as letting you specify the request method.
request :: Yesod site
        => RequestBuilder site ()
        -> YesodExample site ()
request reqBuilder = do
    YesodExampleData app site oldCookies mRes <- ST.get

    RequestBuilderData {..} <- liftIO $ ST.execStateT reqBuilder RequestBuilderData
      { rbdPostData = MultipleItemsPostData []
      , rbdResponse = mRes
      , rbdMethod = "GET"
      , rbdSite = site
      , rbdPath = []
      , rbdGets = []
      , rbdHeaders = []
      }
    let path
            | null rbdPath = "/"
            | otherwise = TE.decodeUtf8 $ Builder.toByteString $ H.encodePathSegments rbdPath

    -- expire cookies and filter them for the current path. TODO: support max age
    currentUtc <- liftIO getCurrentTime
    let cookies = M.filter (checkCookieTime currentUtc) oldCookies
        cookiesForPath = M.filter (checkCookiePath path) cookies

    let req = case rbdPostData of
          MultipleItemsPostData x ->
            if DL.any isFile x
            then (multipart x)
            else singlepart
          BinaryPostData _ -> singlepart
          where singlepart = makeSinglepart cookiesForPath rbdPostData rbdMethod rbdHeaders path rbdGets
                multipart x = makeMultipart cookiesForPath x rbdMethod rbdHeaders path rbdGets
    -- let maker = case rbdPostData of
    --       MultipleItemsPostData x ->
    --         if DL.any isFile x
    --         then makeMultipart
    --         else makeSinglepart
    --       BinaryPostData _ -> makeSinglepart
    -- let req = maker cookiesForPath rbdPostData rbdMethod rbdHeaders path rbdGets
    response <- liftIO $ runSession (srequest req
        { simpleRequest = (simpleRequest req)
            { httpVersion = H.http11
            }
        }) app
    let newCookies = map (Cookie.parseSetCookie . snd) $ DL.filter (("Set-Cookie"==) . fst) $ simpleHeaders response
        cookies' = M.fromList [(Cookie.setCookieName c, c) | c <- newCookies] `M.union` cookies
    ST.put $ YesodExampleData app site cookies' (Just response)
  where
    isFile (ReqFilePart _ _ _ _) = True
    isFile _ = False

    checkCookieTime t c = case Cookie.setCookieExpires c of
                              Nothing -> True
                              Just t' -> t < t'
    checkCookiePath url c =
      case Cookie.setCookiePath c of
        Nothing -> True
        Just x  -> x `BS8.isPrefixOf` TE.encodeUtf8 url

    -- For building the multi-part requests
    boundary :: String
    boundary = "*******noneedtomakethisrandom"
    separator = BS8.concat ["--", BS8.pack boundary, "\r\n"]
    makeMultipart :: M.Map a0 Cookie.SetCookie
                  -> [RequestPart]
                  -> H.Method
                  -> [H.Header]
                  -> T.Text
                  -> H.Query
                  -> SRequest
    makeMultipart cookies parts method extraHeaders urlPath urlQuery =
      SRequest simpleRequest' (simpleRequestBody' parts)
      where simpleRequestBody' x =
              BSL8.fromChunks [multiPartBody x]
            simpleRequest' = mkRequest
                             [ ("Cookie", cookieValue)
                             , ("Content-Type", contentTypeValue)]
                             method extraHeaders urlPath urlQuery
            cookieValue = Builder.toByteString $ Cookie.renderCookies cookiePairs
            cookiePairs = [ (Cookie.setCookieName c, Cookie.setCookieValue c)
                          | c <- map snd $ M.toList cookies ]
            contentTypeValue = BS8.pack $ "multipart/form-data; boundary=" ++ boundary
    multiPartBody parts =
      BS8.concat $ separator : [BS8.concat [multipartPart p, separator] | p <- parts]
    multipartPart (ReqKvPart k v) = BS8.concat
      [ "Content-Disposition: form-data; "
      , "name=\"", TE.encodeUtf8 k, "\"\r\n\r\n"
      , TE.encodeUtf8 v, "\r\n"]
    multipartPart (ReqFilePart k v bytes mime) = BS8.concat
      [ "Content-Disposition: form-data; "
      , "name=\"", TE.encodeUtf8 k, "\"; "
      , "filename=\"", BS8.pack v, "\"\r\n"
      , "Content-Type: ", TE.encodeUtf8 mime, "\r\n\r\n"
      , BS8.concat $ BSL8.toChunks bytes, "\r\n"]

    -- For building the regular non-multipart requests
    makeSinglepart :: M.Map a0 Cookie.SetCookie
                   -> RBDPostData
                   -> H.Method
                   -> [H.Header]
                   -> T.Text
                   -> H.Query
                   -> SRequest
    makeSinglepart cookies rbdPostData method extraHeaders urlPath urlQuery =
      SRequest simpleRequest' (simpleRequestBody' rbdPostData)
      where
        simpleRequest' = (mkRequest
                          [ ("Cookie", cookieValue)
                          , ("Content-Type", "application/x-www-form-urlencoded")]
                          method extraHeaders urlPath urlQuery)
        simpleRequestBody' (MultipleItemsPostData x) =
          BSL8.fromChunks $ return $ TE.encodeUtf8 $ T.intercalate "&"
          $ map singlepartPart x
        simpleRequestBody' (BinaryPostData x) = x
        cookieValue = Builder.toByteString $ Cookie.renderCookies cookiePairs
        cookiePairs = [ (Cookie.setCookieName c, Cookie.setCookieValue c)
                      | c <- map snd $ M.toList cookies ]
        singlepartPart (ReqFilePart _ _ _ _) = ""
        singlepartPart (ReqKvPart k v) = T.concat [k,"=",v]

    -- General request making
    mkRequest headers method extraHeaders urlPath urlQuery = defaultRequest
      { requestMethod = method
      , remoteHost = Sock.SockAddrInet 1 2
      , requestHeaders = headers ++ extraHeaders
      , rawPathInfo = TE.encodeUtf8 urlPath
      , pathInfo = H.decodePathSegments $ TE.encodeUtf8 urlPath
      , rawQueryString = H.renderQuery False urlQuery
      , queryString = urlQuery
      }

-- Yes, just a shortcut
failure :: (MonadIO a) => T.Text -> a b
failure reason = (liftIO $ HUnit.assertFailure $ T.unpack reason) >> error ""
