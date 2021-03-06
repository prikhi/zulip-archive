{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Main where

import Clay ((?), Css, em, pct, px)
import qualified Clay as C
import qualified Config
import Control.Concurrent (threadDelay)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import Data.Time
import Data.Time.Clock.POSIX
import Development.Shake
import GHC.Natural
import Lucid
import Path
import Relude
import Rib (Target)
import qualified Rib
import Text.HTML.TagSoup (maybeTagText, parseTags)
import Web.Slug (mkSlug, unSlug)
import Zulip.Client

data Page
  = Page_Index [Target () Stream]
  | Page_Stream (Target () Stream)
  | Page_Topic (Target () Stream, Target () Topic)

main :: IO ()
main = forever $ do
  cfg <- Config.readConfig
  targetDir <- parseRelDir $ toString $ Config.targetDir cfg
  Rib.runWith [reldir|static|] targetDir (generateSite cfg) (Rib.Generate False)
  putStrLn $ "Waiting for " <> show (Config.fetchEveryMins cfg) <> " min"
  threadDelayMins $ Config.fetchEveryMins cfg
  where
    threadDelayMins :: Natural -> IO ()
    threadDelayMins = threadDelay . (1000000 * 60 *) . naturalToInt

-- | Shake action for generating the static site
generateSite :: Config.Config -> Action ()
generateSite cfg = do
  liftIO $ putStrLn "In build action"
  let baseUrl = Config.baseUrl cfg
  -- Copy over the static files
  Rib.buildStaticFiles [[relfile|**|]]
  -- Fetch (and/or load from cache) all zulip data
  (server, streams) <- getArchive (Config.zulipDomain cfg) (Config.authEmail cfg) (Config.authApiKey cfg)
  streamsT <- forM streams $ \stream -> do
    -- Build the page for a stream
    streamFile <- liftIO $ streamHtmlPath stream
    let streamT = Rib.mkTarget streamFile stream
    Rib.writeTarget streamT $ renderPage server baseUrl . Page_Stream
    forM_ (fromMaybe (error "No topics in stream") $ _streamTopics stream) $ \topic -> do
      -- Build the page for a topic belonging to this stream
      topicFile <- liftIO $ addExtension ".html" $ parent streamFile </> _topicSlug topic
      let topicT = Rib.mkTarget topicFile topic
      Rib.writeTarget topicT $ renderPage server baseUrl . Page_Topic . (streamT,)
    pure streamT
  -- Write an index.html linking to all streams
  let indexT = Rib.mkTarget [relfile|index.html|] streamsT
  Rib.writeTarget indexT $ renderPage server baseUrl . Page_Index . Rib.targetVal

-- TODO: calculate stream slug in Zulip.Client module, along with Topic
streamHtmlPath :: Stream -> IO (Path Rel File)
streamHtmlPath stream = do
  streamSlug <- parseRelDir . toString . unSlug =<< mkSlug (_streamName stream)
  pure $ streamSlug </> [relfile|index.html|]

renderCrumbs :: NonEmpty Page -> Html ()
renderCrumbs (_ :| []) = mempty
renderCrumbs crumbs =
  with div_ [class_ "ui breadcrumb rib"] $ go crumbs
  where
    go :: NonEmpty Page -> Html ()
    go (p0 :| []) = do
      with div_ [class_ "active section"] $ toHtml $ pageName p0
    go (p0 :| p1 : ps) = do
      with a_ [class_ "section", href_ $ pageUrl p0] $ toHtml $ pageName p0
      with i_ [class_ "right angle icon divider"] mempty
      go $ p1 :| ps

pageName :: Page -> Text
pageName = \case
  Page_Index _ -> "Home"
  Page_Stream (Rib.targetVal -> s) -> "#" <> _streamName s
  Page_Topic ((_s, Rib.targetVal -> t)) -> _topicName t

pageUrl :: Page -> Text
pageUrl = \case
  Page_Index _ -> "/"
  Page_Stream s -> Rib.targetUrl s
  Page_Topic (_, t) -> Rib.targetUrl t

pageCrumbs :: Page -> NonEmpty Page
pageCrumbs = (Page_Index [] :|) . \case
  Page_Index _ -> []
  x@(Page_Stream _) -> [x]
  x@(Page_Topic (s, _)) -> [Page_Stream s, x]

-- | Define your site HTML here
renderPage :: ServerSettings -> Text -> Page -> Html ()
renderPage server baseUrl page = with html_ [lang_ "en"] $ do
  let realmName = _serversettingsRealmName server <> " Zulip"
  head_ $ do
    meta_ [httpEquiv_ "Content-Type", content_ "text/html; charset=utf-8"]
    meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]
    ogpMetaTags realmName
    title_ $ toHtml $ pageTitle realmName page
    style_ [type_ "text/css"] $ C.render pageStyle
    stylesheet "https://cdnjs.cloudflare.com/ajax/libs/semantic-ui/2.4.1/semantic.min.css"
    stylesheet "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/5.11.2/css/all.min.css"
    stylesheet "https://fonts.googleapis.com/css?family=Open+Sans|Oswald&display=swap"
    googleFonts $ [headerFont, bodyFont]
  body_ $ do
    with div_ [class_ "ui text container", id_ "thesite"] $ do
      with div_ [class_ "ui violet inverted top attached center aligned segment"] $ do
        with h1_ [class_ "ui huge header"] $ toHtml $ case page of
          Page_Index _ -> realmName <> " Chat Archive"
          Page_Stream (Rib.targetVal -> s) -> _streamName s <> " stream"
          Page_Topic (Rib.targetVal -> s, Rib.targetVal -> t) -> _topicName t <> " - " <> _streamName s
      with div_ [class_ "ui attached segment"] $ do
        with div_ [class_ "ui message"] $ do
          p_ $ do
            "Welcome to the "
            toHtml $ realmName
            " Chat Archive. You can join the chat "
            with a_ [href_ $ _serversettingsRealmUri server] "here"
            "."
        renderCrumbs $ pageCrumbs page
        case page of
          Page_Index streams -> do
            let streamMsgCount (Rib.targetVal -> stream) =
                  length $ mconcat $ _topicMessages <$> fromMaybe [] (_streamTopics stream)
            with div_ [class_ "ui relaxed list"]
              $ forM_ (reverse $ sortOn streamMsgCount streams)
              $ \stream -> with div_ [class_ "item"] $ do
                with div_ [class_ "right floated content subtle"] $
                  case streamMsgCount stream of
                    0 -> mempty
                    cnt -> do
                      toHtml $ show @Text cnt
                      " messages"
                with div_ [class_ "content"] $ do
                  with a_ [class_ "header", href_ (Rib.targetUrl stream)]
                    $ toHtml
                    $ _streamName (Rib.targetVal stream)
                  with div_ [class_ "description"] $ do
                    toHtml (_streamDescription $ Rib.targetVal stream)
          Page_Stream streamT@(Rib.targetVal -> stream) -> do
            p_ $ i_ $ toHtml $ _streamDescription stream
            with div_ [class_ "ui relaxed list"]
              $ forM_ (fromMaybe [] $ _streamTopics stream)
              $ \topic -> with div_ [class_ "item"] $ do
                with div_ [class_ "right floated content subtle"] $ do
                  toHtml $ maybe "" renderTimestamp $ _topicLastUpdated topic
                with div_ [class_ "content"] $ do
                  -- TODO(HACK): We should really be passing `Target Topic` here
                  let topicUrl = Rib.targetUrl streamT <> (toText $ toFilePath $ _topicSlug topic) <> ".html"
                  with a_ [class_ "header", href_ topicUrl]
                    $ toHtml
                    $ _topicName topic
                  with div_ [class_ "description"] $ do
                    toHtml $ show @Text (length $ _topicMessages topic)
                    " messages."
          Page_Topic (_, Rib.targetVal -> topic) -> do
            with div_ [class_ "ui comments messages"] $ do
              forM_ (_topicMessages topic) $ \msg -> do
                with div_ [class_ "comment"] $ do
                  with a_ [class_ "avatar"] $ do
                    case _messageAvatarUrl msg of
                      Nothing -> mempty
                      Just avatarUrl -> img_ [src_ avatarUrl]
                  with div_ [class_ "content"] $ do
                    with a_ [class_ "author"] $ toHtml $ _messageSenderFullName msg
                    with div_ [class_ "metadata"] $ do
                      let anchor = show $ _messageId msg
                      with a_ [name_ anchor, href_ $ "#" <> anchor]
                        $ div_
                        $ renderTimestamp
                        $ _messageTimestamp msg
                    with div_ [class_ "text"] $
                      toHtmlRaw (_messageContent msg)
      with div_ [class_ "ui vertical footer segment"] $ do
        with a_ [href_ "https://github.com/srid/zulip-archive"] "Powered by Haskell"
  where
    renderTimestamp t =
      toHtml $ formatTime defaultTimeLocale "%F %X" $ posixSecondsToUTCTime t
    stylesheet x = link_ [rel_ "stylesheet", href_ x]
    googleFonts fs =
      let s = T.intercalate "|" $ T.replace " " "+" <$> fs
          url = "https://fonts.googleapis.com/css?family=" <> s <> "&display=swap"
       in stylesheet url
    ogpMetaTags :: Text -> Html ()
    ogpMetaTags realmName = do
      let ogpAttribute name value =
            meta_ [term "property" $ "og:" <> name, content_ value]
      ogpAttribute "site_name" $ realmName <> " Archive"
      ogpAttribute "url" $ baseUrl <> pageUrl page
      ogpAttribute "title" $ pageTitle realmName page
      case page of
        Page_Index _ ->
          mempty
        Page_Stream (Rib.targetVal -> s) -> do
          ogpAttribute "description" $ _streamDescription s
        Page_Topic ((Rib.targetVal -> s), Rib.targetVal -> t) -> do
          ogpAttribute "type" "article"
          ogpAttribute "article:section" $ _streamName s
          mapM_ (ogpAttribute "article:modified_time" . ogpTimeFormat) $
            _topicLastUpdated t
          whenJust (listToMaybe $ _topicMessages t) $ \msg -> do
            ogpAttribute "article:published_time" $ ogpTimeFormat $ _messageTimestamp msg
            ogpAttribute "description" $ T.take 300 $ stripHtml $ _messageContent msg
            ogpAttribute "image" `mapM_` _messageAvatarUrl msg
    stripHtml :: Text -> Text
    stripHtml = T.concat . mapMaybe maybeTagText . parseTags
    ogpTimeFormat :: POSIXTime -> Text
    ogpTimeFormat =
      toText
        . formatTime defaultTimeLocale (iso8601DateFormat $ Just "%H:%M:%SZ")
        . posixSecondsToUTCTime

pageTitle :: Text -> Page -> Text
pageTitle realmName = \case
  Page_Index _ -> realmName <> " Archive"
  Page_Stream (Rib.targetVal -> s) -> do
    _streamName s <> " - " <> realmName
  Page_Topic (Rib.targetVal -> s, Rib.targetVal -> t) -> do
    _topicName t <> " - " <> _streamName s

headerFont :: Text
headerFont = "Roboto"

bodyFont :: Text
bodyFont = "Open Sans"

-- | Define your site CSS here
pageStyle :: Css
pageStyle = "div#thesite" ? do
  baseStyle
  C.marginTop $ em 1
  C.marginBottom $ em 1
  ".ui.breadcrumb.rib" ? do
    C.marginBottom $ em 1
  ".ui.comments.messages" ? do
    ".comment" ? do
      ".metadata a" ? do
        C.color C.grey
      "a.avatar img" ? do
        C.height C.auto -- Fix vertical stretching of avatar
  ".subtle" ? do
    C.color C.grey
  ".messages" ? do
    "pre" ? do
      C.fontSize $ pct 85
      C.overflow C.auto
      C.maxWidth $ pct 100
    ".message_embed" ? do
      C.borderLeft C.solid (px 3) C.grey
      C.paddingLeft $ em 0.7
    ".message_inline_image img" ? do
      C.maxWidth $ pct 100
      C.marginBottom $ em 1
  where
    baseStyle :: Css
    baseStyle = do
      -- Fonts
      C.fontFamily [bodyFont] [C.sansSerif]
      forM_ [C.h1, C.h2, C.h3, C.h4, C.h5, C.h6, ".ui.breadcrumb.rib .section", ".header", ".as-header"] $ \h -> h ? do
        C.fontFamily [headerFont] [C.sansSerif]
        C.lineHeight $ em 1.2
      "code, pre, tt"
        ? C.fontFamily ["SFMono-Regular", "Menlo", "Monaco", "Consolas", "Liberation Mono", "Courier New"] [C.monospace]
      -- Get rid of the font lock in text container
      C.important $ C.fontSize $ em 1
