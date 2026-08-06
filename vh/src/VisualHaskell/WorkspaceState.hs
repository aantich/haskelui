{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.WorkspaceState
  ( WorkspaceState (..)
  , decodeWorkspaceState
  , defaultInspectorPaneState
  , defaultNavigatorPaneState
  , encodeWorkspaceState
  , fromWorkspaceRelativePath
  , toWorkspaceRelativePath
  , workspaceFileName
  , workspaceFilePath
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  , (.=)
  )
import Data.Aeson.Types (Parser)
import qualified Data.Aeson.Key as AesonKey
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import System.FilePath
  ( (</>)
  , isAbsolute
  , joinPath
  , makeRelative
  , normalise
  , splitDirectories
  )
import HaskeLUI.Core
  ( PaneState (..)
  , PaneVisibility (..)
  )

workspaceFileName :: FilePath
workspaceFileName = ".vihs"

workspaceFilePath :: FilePath -> FilePath
workspaceFilePath root = normalise root </> workspaceFileName

defaultNavigatorPaneState :: PaneState
defaultNavigatorPaneState = PaneState PaneVisible (Just 230)

defaultInspectorPaneState :: PaneState
defaultInspectorPaneState = PaneState PaneVisible (Just 270)

data WorkspaceState = WorkspaceState
  { workspaceOpenFiles :: ![FilePath]
  , workspaceActiveFile :: !(Maybe FilePath)
  , workspaceExpandedFolders :: ![FilePath]
  , workspaceSelectedExplorerEntry :: !(Maybe FilePath)
  , workspaceNavigatorPane :: !PaneState
  , workspaceInspectorPane :: !PaneState
  , workspaceAnalysisTrusted :: !Bool
  }
  deriving stock (Eq, Show)

instance ToJSON WorkspaceState where
  toJSON state =
    object
      [ "format" .= ("visual-haskell-workspace" :: Text)
      , "version" .= (2 :: Int)
      , "openFiles" .= fmap Text.pack state.workspaceOpenFiles
      , "activeFile" .= fmap Text.pack state.workspaceActiveFile
      , "expandedFolders" .= fmap Text.pack state.workspaceExpandedFolders
      , "selectedExplorerEntry" .= fmap Text.pack state.workspaceSelectedExplorerEntry
      , "panes"
          .= object
            [ "navigator" .= paneValue state.workspaceNavigatorPane
            , "inspector" .= paneValue state.workspaceInspectorPane
            ]
      , "analysisTrusted" .= state.workspaceAnalysisTrusted
      ]

instance FromJSON WorkspaceState where
  parseJSON = withObject "Visual Haskell workspace" $ \value -> do
    format <- value .: "format"
    version <- value .: "version"
    if (format :: Text) /= "visual-haskell-workspace"
      then fail "unexpected workspace format"
      else pure ()
    if (version :: Int) `notElem` [1, 2]
      then fail ("unsupported workspace version " <> show version)
      else pure ()
    openFiles <- value .:? "openFiles" .!= []
    activeFile <- value .:? "activeFile"
    expandedFolders <- value .:? "expandedFolders" .!= ["."]
    selectedEntry <- value .:? "selectedExplorerEntry"
    panes <- value .:? "panes"
    navigator <- maybe (pure defaultNavigatorPaneState) (parseNamedPane "navigator" defaultNavigatorPaneState) panes
    inspector <- maybe (pure defaultInspectorPaneState) (parseNamedPane "inspector" defaultInspectorPaneState) panes
    analysisTrusted <-
      if (version :: Int) >= 2
        then value .:? "analysisTrusted" .!= False
        else pure False
    parsedOpenFiles <- traverse (validateForParser "openFiles") openFiles
    parsedActiveFile <- traverse (validateForParser "activeFile") activeFile
    parsedExpandedFolders <- traverse (validateForParser "expandedFolders") expandedFolders
    parsedSelectedEntry <- traverse (validateForParser "selectedExplorerEntry") selectedEntry
    let uniqueOpenFiles = nub parsedOpenFiles
        active = parsedActiveFile >>= \path -> if path `elem` uniqueOpenFiles then Just path else Nothing
    pure
      WorkspaceState
        { workspaceOpenFiles = uniqueOpenFiles
        , workspaceActiveFile = active
        , workspaceExpandedFolders = nub ("." : parsedExpandedFolders)
        , workspaceSelectedExplorerEntry = parsedSelectedEntry
        , workspaceNavigatorPane = navigator
        , workspaceInspectorPane = inspector
        , workspaceAnalysisTrusted = analysisTrusted
        }

paneValue :: PaneState -> Value
paneValue pane =
  object
    [ "visibility"
        .= case pane.paneVisibility of
          PaneVisible -> ("visible" :: Text)
          PaneCollapsed -> "collapsed"
    , "extent" .= pane.paneExtent
    ]

parseNamedPane :: Text -> PaneState -> Value -> Parser PaneState
parseNamedPane name fallback = withObject "workspace panes" $ \panes -> do
  pane <- panes .:? AesonKey.fromText name
  maybe (pure fallback) (parsePaneValue name fallback) pane

parsePaneValue :: Text -> PaneState -> Value -> Parser PaneState
parsePaneValue name fallback = withObject (Text.unpack name <> " pane") $ \value -> do
  visibility <- value .:? "visibility" .!= visibilityText fallback.paneVisibility
  extent <- value .:? "extent" .!= fallback.paneExtent
  parsedVisibility <-
    case (visibility :: Text) of
      "visible" -> pure PaneVisible
      "collapsed" -> pure PaneCollapsed
      _ -> fail ("invalid " <> Text.unpack name <> " pane visibility")
  pure (PaneState parsedVisibility extent)

visibilityText :: PaneVisibility -> Text
visibilityText PaneVisible = "visible"
visibilityText PaneCollapsed = "collapsed"

validateForParser :: Text -> Text -> Parser FilePath
validateForParser field path =
  either (fail . Text.unpack) pure (validateStoredPath field path)

encodeWorkspaceState :: WorkspaceState -> Text
encodeWorkspaceState =
  TextEncoding.decodeUtf8
    . LazyByteString.toStrict
    . encode

decodeWorkspaceState :: Text -> Either Text WorkspaceState
decodeWorkspaceState =
  either (Left . Text.pack) Right
    . eitherDecodeStrict'
    . TextEncoding.encodeUtf8

toWorkspaceRelativePath :: FilePath -> FilePath -> Maybe FilePath
toWorkspaceRelativePath root requestedPath = do
  let relative = normalise (makeRelative (normalise root) (normalise requestedPath))
      portable = Text.unpack (Text.intercalate "/" (fmap Text.pack (splitDirectories relative)))
  either (const Nothing) Just (validateStoredPath "path" (Text.pack portable))

fromWorkspaceRelativePath :: FilePath -> FilePath -> Maybe FilePath
fromWorkspaceRelativePath root storedPath = do
  valid <- either (const Nothing) Just (validateStoredPath "path" (Text.pack storedPath))
  if valid == "."
    then pure (normalise root)
    else do
      let relative = joinPath (fmap Text.unpack (Text.splitOn "/" (Text.pack valid)))
      pure (normalise (root </> relative))

validateStoredPath :: Text -> Text -> Either Text FilePath
validateStoredPath field raw
  | Text.null raw = Left (field <> " contains an empty path")
  | Text.any (== '\\') raw = Left (field <> " must use '/' separators")
  | isAbsolute unpacked = Left (field <> " contains an absolute path")
  | raw == "." = Right "."
  | any invalidComponent components = Left (field <> " contains an unsafe path")
  | otherwise = Right unpacked
  where
    unpacked = Text.unpack raw
    components = Text.splitOn "/" raw
    invalidComponent component = Text.null component || component == "." || component == ".."
