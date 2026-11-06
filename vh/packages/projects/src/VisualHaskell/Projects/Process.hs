{-# LANGUAGE OverloadedStrings #-}
module VisualHaskell.Projects.Process (ToolRunner, runTool) where

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
import System.Process
import System.Posix.Signals (signalProcessGroup, sigTERM, sigKILL)
import System.Timeout

type ToolRunner = FilePath -> FilePath -> [String] -> IO Text

-- Streams are drained concurrently and logs/results are bounded. A process
-- group keeps cancellation from leaving Cabal/Stack/Setup/GHC descendants.
runTool :: (Text -> IO ()) -> ToolRunner
runTool progress directory executable arguments = do
  progress (Text.pack (showCommandForUser executable arguments))
  result <- timeout (15 * 60 * 1000000) $
    withCreateProcess ((proc executable arguments)
      {cwd = Just directory, std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe, create_group = True}) $
      \_ out err child -> do
        pid <- getPid child
        let cleanup = do
              status <- getProcessExitCode child
              case status of
                Nothing -> do
                  let signal sig = maybe (pure ()) (\group -> signalProcessGroup sig group `catch` ignore) pid
                  signal sigTERM
                  threadDelay 100000
                  signal sigKILL
                  void (timeout 1000000 (waitForProcess child))
                Just _ -> pure ()
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
      let loop = do
            bytes <- BS.hGetSome handle 4096
            unless (BS.null bytes) $ do
              let message = Text.decodeUtf8With lenientDecode bytes
              whenOutput isError message
              count <- readIORef retained
              if count < 2 * 1024 * 1024
                then modifyIORef' chunks (bytes :) >> modifyIORef' retained (+ BS.length bytes)
                else modifyIORef' retained (+ BS.length bytes)
              loop
      loop
      count <- readIORef retained
      if count > 2 * 1024 * 1024
        then ioError (userError "Project tool output exceeded the 2 MiB safety limit; inspect the build-tool log")
        else Text.decodeUtf8With lenientDecode . BS.concat . reverse <$> readIORef chunks
    whenOutput True message = progress (Text.take 4096 message)
    whenOutput False _ = pure ()
    ignore :: IOException -> IO ()
    ignore _ = pure ()
