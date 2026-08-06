{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (stripPrefix)
import qualified Data.Text as Text
import System.Directory (doesFileExist, findExecutable)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>), takeDirectory)
import System.IO (hPutStrLn, stderr)
import VisualHaskell (applicationWithAnalysisEnvironment)
import VisualHaskell.Analysis.Client (WorkerLaunch (..))
import VisualHaskell.Analysis.Service
  ( AnalysisConfiguration (..)
  , defaultAnalysisConfiguration
  )
import VisualHaskell.Logging (DebugLogger (..), withDebugLogger)
import VisualHaskell.Paths
  ( VisualHaskellPaths (..)
  , ensureVisualHaskellPaths
  , resolveVisualHaskellPaths
  )
import VisualHaskell.TextMate
  ( TextMateConfiguration (..)
  , defaultTextMateConfiguration
  )
import HaskeLUI.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import HaskeLUI.Core (noTrace, trace, TraceSeverity (TraceInfo))
import HaskeLUI.Runtime
  ( RuntimeOptions (..)
  , defaultRuntimeOptions
  , runAppWith
  )

data CommandLine = CommandLine
  { commandDebug :: !Bool
  , commandDebugPath :: !(Maybe FilePath)
  , commandHelp :: !Bool
  }

main :: IO ()
main = do
  arguments <- getArgs
  case parseCommandLine arguments of
    Left message -> do
      hPutStrLn stderr message
      hPutStrLn stderr usage
      exitFailure
    Right commandLine
      | commandLine.commandHelp -> putStrLn usage >> exitSuccess
      | otherwise -> do
          paths <- resolveVisualHaskellPaths
          ensureVisualHaskellPaths paths
          if commandLine.commandDebug
            then
              withDebugLogger
                paths.visualHaskellLogDirectory
                commandLine.commandDebugPath
                (runVisualHaskell paths . Just)
            else runVisualHaskell paths Nothing

runVisualHaskell :: VisualHaskellPaths -> Maybe DebugLogger -> IO ()
runVisualHaskell paths maybeLogger = do
  let sink = maybe noTrace (.debugTraceSink) maybeLogger
  trace sink TraceInfo "visual-haskell" "startup"
    [ ("home", Text.pack paths.visualHaskellHome)
    , ("state", Text.pack paths.visualHaskellStateDirectory)
    ]
  capabilities <- queryAppKitCapabilities
  textMateDefaults <- defaultTextMateConfiguration paths.visualHaskellHome
  analysisWorker <- resolveAnalysisWorker
  let textMateConfiguration = textMateDefaults {textMateTraceSink = sink}
      analysisDefaults = defaultAnalysisConfiguration analysisWorker
      launchDefaults = analysisDefaults.analysisWorkerLaunch
      analysisConfiguration =
        analysisDefaults
          { analysisTraceSink = sink
          , analysisWorkerLaunch =
              launchDefaults
                { workerArguments =
                    launchDefaults.workerArguments
                      <> ["--debug" | maybe False (const True) maybeLogger]
                }
          }
      runtimeOptions = defaultRuntimeOptions {runtimeTraceSink = sink}
  putStrLn ("Starting Visual Haskell on " <> show capabilities.appKitVersion)
  case maybeLogger of
    Nothing -> pure ()
    Just logger -> putStrLn ("Detailed debug log: " <> logger.debugLogPath)
  runAppWith
    runtimeOptions
    appKitBackend
    ( applicationWithAnalysisEnvironment
        paths.visualHaskellLastWorkspacePath
        textMateConfiguration
        analysisConfiguration
    )

parseCommandLine :: [String] -> Either String CommandLine
parseCommandLine = go (CommandLine False Nothing False)
  where
    go commandLine [] = Right commandLine
    go commandLine ("--debug" : rest) =
      go commandLine {commandDebug = True} rest
    go commandLine ("--debug-log" : path : rest) =
      go commandLine {commandDebug = True, commandDebugPath = Just path} rest
    go _ ["--debug-log"] = Left "--debug-log requires a file path"
    go commandLine ("--help" : rest) =
      go commandLine {commandHelp = True} rest
    go commandLine (argument : rest)
      | Just path <- stripPrefix "--debug=" argument
      , not (null path) =
          go commandLine {commandDebug = True, commandDebugPath = Just path} rest
      | otherwise = Left ("Unknown Visual Haskell option: " <> argument)

usage :: String
usage =
  unlines
    [ "Usage: vh [--debug] [--debug=PATH | --debug-log PATH]"
    , ""
    , "  --debug           Enable detailed structured logging."
    , "  --debug=PATH      Write the JSONL debug session to PATH."
    , "  --debug-log PATH  Equivalent spelling for --debug=PATH."
    ]

resolveAnalysisWorker :: IO FilePath
resolveAnalysisWorker = do
  currentExecutable <- getExecutablePath
  let executableName = "visual-haskell-analysis-ghc910"
      sibling = takeDirectory currentExecutable </> executableName
  siblingExists <- doesFileExist sibling
  if siblingExists
    then pure sibling
    else maybe executableName id <$> findExecutable executableName
