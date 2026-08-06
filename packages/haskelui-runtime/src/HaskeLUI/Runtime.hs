{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

module HaskeLUI.Runtime
  ( Backend (..)
  , BackendSession (..)
  , runApp
  ) where

import Control.Exception
  ( IOException
  , bracketOnError
  , displayException
  , finally
  , try
  )
import Control.Monad
  ( forM
  , forM_
  , when
  )
import qualified Data.ByteString as ByteString
import Data.List (sortOn)
import Data.IORef
  ( newIORef
  , readIORef
  , writeIORef
  )
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import System.Directory
  ( doesFileExist
  , doesDirectoryExist
  , listDirectory
  , removeFile
  , renameFile
  )
import System.FilePath
  ( (</>)
  , normalise
  , takeDirectory
  , takeFileName
  )
import System.IO
  ( Handle
  , hClose
  , hFlush
  , openBinaryTempFile
  )
import HaskeLUI.Core
  ( App (..)
  , AppView (..)
  , Effect (..)
  , FileSystemEntry (..)
  , FileSystemEntryKind (..)
  , UIEvent (..)
  , applyTransaction
  , resolveAppViewLayouts
  , transactionEffects
  )

newtype Backend = Backend
  { openBackend :: (UIEvent -> IO ()) -> IO BackendSession
  }

data BackendSession = BackendSession
  { backendRender :: AppView -> IO ()
  , backendRequestOpenTextFiles :: IO ()
  , backendRequestOpenProjectFolder :: IO ()
  , backendRun :: IO ()
  , backendStop :: IO ()
  , backendShutdown :: IO ()
  }

runApp :: Backend -> App model -> IO ()
runApp backend application = do
  modelReference <- newIORef application.appInitialModel
  sessionReference <- newIORef Nothing
  session <- openBackend backend (dispatch modelReference sessionReference)
  writeIORef sessionReference (Just session)
  backendRender session (fst (resolveAppViewLayouts (application.appView application.appInitialModel)))
  forM_ application.appInitialEffects $
    interpretEffect session (dispatch modelReference sessionReference)
  backendRun session `finally` backendShutdown session
  where
    dispatch modelReference sessionReference event = do
      model <- readIORef modelReference
      let update = application.appHandleEvent event model
          updated = applyTransaction update model
          desired = fst (resolveAppViewLayouts (application.appView updated))
      writeIORef modelReference updated
      maybeSession <- readIORef sessionReference
      case maybeSession of
        Nothing -> pure ()
        Just session -> do
          backendRender session desired
          when (null desired.appWindows) (backendStop session)
          forM_ update.transactionEffects $
            interpretEffect session (dispatch modelReference sessionReference)

interpretEffect :: BackendSession -> (UIEvent -> IO ()) -> Effect -> IO ()
interpretEffect session dispatch = \case
  RequestOpenTextFiles -> backendRequestOpenTextFiles session
  RequestOpenProjectFolder -> backendRequestOpenProjectFolder session
  ReadDirectory path -> do
    result <- try (readDirectoryEntries path) :: IO (Either IOException [FileSystemEntry])
    dispatch $
      DirectoryRead path $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right entries -> Right entries
  ReadTextFile path -> do
    result <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
    dispatch $
      TextFileRead path $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right bytes ->
            case TextEncoding.decodeUtf8' (dropUtf8Bom bytes) of
              Left exception -> Left (Text.pack (displayException exception))
              Right contents -> Right contents
  ReadOptionalTextFile path -> do
    exists <- doesFileExist path
    if not exists
      then dispatch (OptionalTextFileRead path (Right Nothing))
      else do
        result <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
        dispatch $
          OptionalTextFileRead path $
            case result of
              Left exception -> Left (Text.pack (displayException exception))
              Right bytes ->
                case TextEncoding.decodeUtf8' (dropUtf8Bom bytes) of
                  Left exception -> Left (Text.pack (displayException exception))
                  Right contents -> Right (Just contents)
  WriteTextFile key path contents -> do
    result <- try (ByteString.writeFile path (TextEncoding.encodeUtf8 contents)) :: IO (Either IOException ())
    dispatch $
      TextFileWritten key path contents $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right () -> Right ()
  WriteTextFileAtomically key path contents -> do
    result <-
      try (writeTextFileAtomically path (TextEncoding.encodeUtf8 contents))
        :: IO (Either IOException ())
    dispatch $
      TextFileWritten key path contents $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right () -> Right ()

writeTextFileAtomically :: FilePath -> ByteString.ByteString -> IO ()
writeTextFileAtomically path bytes =
  bracketOnError
    (openBinaryTempFile (takeDirectory path) (takeFileName path <> ".tmp"))
    cleanupTemporaryFile
    (\(temporaryPath, handle) -> do
      ByteString.hPut handle bytes
      hFlush handle
      hClose handle
      renameFile temporaryPath path
    )

cleanupTemporaryFile :: (FilePath, Handle) -> IO ()
cleanupTemporaryFile (temporaryPath, handle) = do
  ignoreIOException (hClose handle)
  ignoreIOException (removeFile temporaryPath)

ignoreIOException :: IO () -> IO ()
ignoreIOException operation = do
  result <- try operation :: IO (Either IOException ())
  case result of
    Left _ -> pure ()
    Right () -> pure ()

dropUtf8Bom :: ByteString.ByteString -> ByteString.ByteString
dropUtf8Bom bytes =
  maybe bytes id (ByteString.stripPrefix (ByteString.pack [0xEF, 0xBB, 0xBF]) bytes)

readDirectoryEntries :: FilePath -> IO [FileSystemEntry]
readDirectoryEntries directory = do
  names <- listDirectory directory
  entries <- forM names $ \name -> do
    let path = normalise (directory </> name)
    isDirectory <- doesDirectoryExist path
    pure
      FileSystemEntry
        { fileSystemEntryPath = path
        , fileSystemEntryName = Text.pack name
        , fileSystemEntryKind =
            if isDirectory then FileSystemDirectory else FileSystemFile
        }
  pure (sortOn entryOrder entries)
  where
    entryOrder :: FileSystemEntry -> (Int, Text.Text)
    entryOrder entry =
      ( case entry.fileSystemEntryKind of
          FileSystemDirectory -> (0 :: Int)
          FileSystemFile -> 1
      , Text.toCaseFold entry.fileSystemEntryName
      )
