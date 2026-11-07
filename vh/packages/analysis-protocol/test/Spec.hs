{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import Data.Aeson (Value, decode, encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import System.Directory (getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.IO
  ( Handle
  , SeekMode (AbsoluteSeek)
  , hClose
  , hSeek
  , openBinaryTempFile
  )
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

main :: IO ()
main = do
  fixture <- LazyByteString.readFile ("test" </> "fixtures" </> "client-hello.json")
  let message =
        protocolEnvelope
          (WorkspaceGeneration 0)
          ( ClientHelloMessage
              (ClientHello "0.1.0" Nothing UntrustedWorkspace [WorkspaceLoadingCapability, DiagnosticsCapability])
          )
  assertEqual "client hello semantic golden" (decode fixture :: Maybe Value) (decode (encode message))
  assertEqual "client hello JSON round trip" (Just message) (decode (encode message))
  assertEqual "project protocol major" 2 (protocolMajor protocolV2)
  let profile = ProjectProfile "cabal:root" CabalProject "/project" (Just "/project/cabal.project")
      component = ProjectComponent (ComponentId "pkg:lib") "pkg" "library" "lib:pkg" LibraryComponent "/project/pkg" ["/project/pkg/src"] [] []
      catalog = ProjectCatalog [profile] (Just "cabal:root") [component] ["/project/cabal.project"] []
      context = ResolvedContext (ComponentId "pkg:lib") "/project" ["-Wall"] "/ghc/lib" (CompilerVersion "9.10.3")
        ["/project/cabal.project"] ["/project/pkg/src"] [] (SessionId "context-1") (Just "pkg-unit")
        [("pkg-unit", ["/project/pkg/src"])] [("pkg-unit", "/project/pkg")]
  mapM_ (\payload -> assertEqual "project request round trip" (Just payload) (decode (encode payload)))
    [DiscoverProject Nothing, PrepareComponent (ComponentId "pkg:lib"), ConfigureContext context,
      RefreshToolchains, SelectCompiler Nothing, SelectCompiler (Just "/installed/ghc"), BuildAnalysisWorker, OpenToolchainManager]
  mapM_ (\payload -> assertEqual "project event round trip" (Just payload) (decode (encode payload)))
    [ProjectDiscovered catalog, ProjectProgress "Preparing pkg", ProjectConfigurationChanged ["/project/cabal.project"],
      ToolchainsDiscovered emptyToolchainInventory]
  let query = QueryPosition (PositionQuery CompletionQuery 17)
      result = PositionQueryCompleted (PositionResult (PositionQuery HoverQuery 5)
        (Just (HoverInfo "map" "(a -> b) -> [a] -> [b]" (Just "Prelude") 4 3)) [] [] 4 0)
  assertEqual "position query wire round trip" (Just query) (decode (encode query))
  assertEqual "position result wire round trip" (Just result) (decode (encode result))
  let composition = CompositionQuery [DeclarationId "first", DeclarationId "second"]
      checked = CompositionChecked (CompositionResult composition True (Just "Int -> String") Nothing)
  assertEqual "composition request wire round trip" (Just (CheckComposition composition)) (decode (encode (CheckComposition composition)))
  assertEqual "composition result wire round trip" (Just checked) (decode (encode checked))
  assertEqual
    "unknown capabilities survive minor-version negotiation"
    (Just (UnsupportedCapability "future-capability"))
    (decode (encode (UnsupportedCapability "future-capability")))
  withTemporaryBinaryFile $ \handle -> do
    written <- writeFrame defaultFrameLimits handle message
    assertEqual "bounded frame writes" (Right ()) written
    hSeek handle AbsoluteSeek 0
    readBack <- readFrame defaultFrameLimits handle
    assertEqual "bounded frame round trip" (Right message) readBack
  withTemporaryBinaryFile $ \handle -> do
    ByteString.hPut handle (ByteString.pack [0, 0, 0, 5, 123, 125])
    hSeek handle AbsoluteSeek 0
    truncated <- readFrame defaultFrameLimits handle :: IO (Either FrameError Value)
    assertEqual "truncated frame rejected" (Left (FrameUnexpectedEnd 5 2)) truncated
  withTemporaryBinaryFile $ \handle -> do
    ByteString.hPut handle (ByteString.pack [0, 0, 1, 0])
    hSeek handle AbsoluteSeek 0
    oversized <- readFrame (FrameLimits 32) handle :: IO (Either FrameError Value)
    assertEqual "oversized frame rejected before allocation" (Left (FrameTooLarge 256 32)) oversized
  putStrLn "Visual Haskell analysis protocol tests passed"

withTemporaryBinaryFile :: (Handle -> IO value) -> IO value
withTemporaryBinaryFile use = do
  temporary <- getTemporaryDirectory
  bracket
    (openBinaryTempFile temporary "visual-haskell-protocol")
    (\(path, handle) -> hClose handle >> removeFile path)
    (use . snd)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual message expected actual =
  unless (expected == actual) $
    fail (message <> ": expected " <> show expected <> ", got " <> show actual)
