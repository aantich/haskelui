{-# LANGUAGE OverloadedStrings #-}
module VisualHaskell.Projects.Process (ToolRunner, EnvironmentToolRunner, runTool, runToolWithEnvironment, runToolInExistingGroup) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent (threadDelay)
import Control.Exception (finally, IOException, catch)
import Control.Monad (unless, void)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Text.Encoding.Error (lenientDecode)
import System.Exit
import System.Environment (getEnvironment)
import System.Process
import System.Posix.Signals (signalProcess, signalProcessGroup, sigTERM, sigKILL)
import System.Timeout

type ToolRunner = FilePath -> FilePath -> [String] -> IO Text
type EnvironmentToolRunner = [(String, String)] -> ToolRunner

-- Streams are drained concurrently and logs/results are bounded. A process
-- group keeps cancellation from leaving Cabal/Stack/Setup/GHC descendants.
runTool :: (Text -> IO ()) -> ToolRunner
runTool progress = runToolWithEnvironment progress []

runToolWithEnvironment :: (Text -> IO ()) -> EnvironmentToolRunner
runToolWithEnvironment = runGrouped True

-- Preparation is already an isolated supervised process group. Its nested
-- tools must inherit that group so killing the helper also reaps their GHCs.
runToolInExistingGroup :: (Text -> IO ()) -> EnvironmentToolRunner
runToolInExistingGroup = runGrouped False

runGrouped :: Bool -> (Text -> IO ()) -> EnvironmentToolRunner
runGrouped ownGroup progress overrides directory executable arguments = do
  progress (Text.pack (showCommandForUser executable arguments))
  -- stack exec exports the editor's package database, not the project's.
  -- Cabal rejects GHC_PACKAGE_PATH and GHC_ENVIRONMENT can load unrelated units.
  inherited <- getEnvironment
  let environment = overrides <> filter (\(name, _) -> name `notElem`
        (["GHC_PACKAGE_PATH", "GHC_ENVIRONMENT"] <> map fst overrides)) inherited
  result <- timeout (15 * 60 * 1000000) $
    withCreateProcess ((proc executable arguments)
      {cwd = Just directory, env = Just environment, std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe, create_group = ownGroup}) $
      \_ out err child -> do
        pid <- getPid child
        let cleanup = do
              -- A wrapper can exit before a child which still owns its pipes.
              -- Keep the original group ID and reap descendants even then.
              let signal sig = maybe (pure ()) (\identifier ->
                    (if ownGroup then signalProcessGroup sig identifier else signalProcess sig identifier) `catch` ignore) pid
              signal sigTERM
              status <- getProcessExitCode child
              case status of
                Nothing -> threadDelay 100000
                Just _ -> pure ()
              signal sigKILL
              void (timeout 1000000 (waitForProcess child))
        flip finally cleanup $ do
          (output, errors) <- concurrently (drain False out) (drain True err)
          status <- waitForProcess child
          unless (status == ExitSuccess) $
            ioError (userError (showCommandForUser executable arguments <> " failed (" <> show status <> ")\n" <> Text.unpack errors <> Text.unpack output))
          pure output
  maybe (ioError (userError (executable <> " exceeded the 15 minute project operation limit"))) pure result
  where
    drain _ Nothing = pure ""
    drain isError (Just handle) = do
      chunks <- newIORef []
      retained <- newIORef (0 :: Int)
      logBuffer <- newIORef BS.empty
      let emitLines pending = case BS.break (== 10) pending of
            (line, rest) | not (BS.null rest) ->
              progress (Text.decodeUtf8With lenientDecode line) >> emitLines (BS.drop 1 rest)
            _ | BS.length pending >= 4096 ->
              progress (Text.decodeUtf8With lenientDecode (BS.take 4096 pending)) >> emitLines (BS.drop 4096 pending)
            _ -> pure pending
          loop = do
            bytes <- BS.hGetSome handle 4096
            unless (BS.null bytes) $ do
              if isError then do
                previous <- readIORef logBuffer
                remaining <- emitLines (previous <> bytes)
                writeIORef logBuffer remaining
              else pure ()
              count <- readIORef retained
              if count < 2 * 1024 * 1024
                then modifyIORef' chunks (bytes :) >> modifyIORef' retained (+ BS.length bytes)
                else modifyIORef' retained (+ BS.length bytes)
              loop
      loop
      remaining <- readIORef logBuffer
      unless (BS.null remaining) (progress (Text.decodeUtf8With lenientDecode remaining))
      count <- readIORef retained
      if count > 2 * 1024 * 1024
        then ioError (userError "Project tool output exceeded the 2 MiB safety limit; inspect the build-tool log")
        else Text.decodeUtf8With lenientDecode . BS.concat . reverse <$> readIORef chunks
    ignore :: IOException -> IO ()
    ignore _ = pure ()
