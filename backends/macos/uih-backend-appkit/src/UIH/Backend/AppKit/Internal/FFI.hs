{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module UIH.Backend.AppKit.Internal.FFI
  ( CMacRect (..)
  , EventCallback
  , MacControlHandle
  , MacWindowHandle
  , c_commandRemove
  , c_commandSet
  , c_controlDestroy
  , c_controlFocus
  , c_controlSetEnabled
  , c_controlSetFrame
  , c_controlSetText
  , c_createButton
  , c_createLabel
  , c_createTextField
  , c_createWindow
  , c_initialize
  , c_run
  , c_shutdown
  , c_stop
  , c_versionMajor
  , c_versionMinor
  , c_versionPatch
  , c_windowDestroy
  , c_windowSetTitle
  , c_windowShow
  , makeEventCallback
  , withMacRect
  ) where

import Foreign
  ( FunPtr
  , Ptr
  , Storable (..)
  , alloca
  , pokeByteOff
  )
import Foreign.C
  ( CDouble (..)
  , CInt (..)
  , CString
  )
import Data.Word (Word64)
import UIH.Core (Rect (..))

data MacWindowHandle
data MacControlHandle

data CMacRect = CMacRect
  !CDouble
  !CDouble
  !CDouble
  !CDouble
  deriving stock (Eq, Show)

instance Storable CMacRect where
  sizeOf _ = 32
  alignment _ = alignment (undefined :: CDouble)
  peek pointer =
    CMacRect
      <$> peekByteOff pointer 0
      <*> peekByteOff pointer 8
      <*> peekByteOff pointer 16
      <*> peekByteOff pointer 24
  poke pointer (CMacRect x y width height) = do
    pokeByteOff pointer 0 x
    pokeByteOff pointer 8 y
    pokeByteOff pointer 16 width
    pokeByteOff pointer 24 height

withMacRect :: Rect -> (Ptr CMacRect -> IO result) -> IO result
withMacRect (Rect x y width height) use =
  alloca $ \pointer -> do
    poke pointer (CMacRect (realToFrac x) (realToFrac y) (realToFrac width) (realToFrac height))
    use pointer

type EventCallback = Ptr () -> CInt -> Word64 -> CString -> IO ()

foreign import ccall "wrapper"
  makeEventCallback :: EventCallback -> IO (FunPtr EventCallback)

foreign import ccall unsafe "uih_macos_initialize"
  c_initialize :: FunPtr EventCallback -> Ptr () -> IO CInt

foreign import ccall safe "uih_macos_run"
  c_run :: IO ()

foreign import ccall unsafe "uih_macos_stop"
  c_stop :: IO ()

foreign import ccall unsafe "uih_macos_shutdown"
  c_shutdown :: IO ()

foreign import ccall unsafe "uih_macos_version_major"
  c_versionMajor :: IO CInt

foreign import ccall unsafe "uih_macos_version_minor"
  c_versionMinor :: IO CInt

foreign import ccall unsafe "uih_macos_version_patch"
  c_versionPatch :: IO CInt

foreign import ccall unsafe "uih_macos_window_create"
  c_createWindow :: Word64 -> CString -> Ptr CMacRect -> IO (Ptr MacWindowHandle)

foreign import ccall unsafe "uih_macos_window_set_title"
  c_windowSetTitle :: Ptr MacWindowHandle -> CString -> IO ()

foreign import ccall unsafe "uih_macos_window_show"
  c_windowShow :: Ptr MacWindowHandle -> IO ()

foreign import ccall unsafe "uih_macos_window_destroy"
  c_windowDestroy :: Ptr MacWindowHandle -> IO ()

foreign import ccall unsafe "uih_macos_label_create"
  c_createLabel :: Ptr MacWindowHandle -> Word64 -> CString -> Ptr CMacRect -> IO (Ptr MacControlHandle)

foreign import ccall unsafe "uih_macos_button_create"
  c_createButton :: Ptr MacWindowHandle -> Word64 -> CString -> Word64 -> Ptr CMacRect -> IO (Ptr MacControlHandle)

foreign import ccall unsafe "uih_macos_text_field_create"
  c_createTextField :: Ptr MacWindowHandle -> Word64 -> CString -> CString -> Ptr CMacRect -> IO (Ptr MacControlHandle)

foreign import ccall unsafe "uih_macos_control_set_text"
  c_controlSetText :: Ptr MacControlHandle -> CString -> IO ()

foreign import ccall unsafe "uih_macos_control_set_frame"
  c_controlSetFrame :: Ptr MacControlHandle -> Ptr CMacRect -> IO ()

foreign import ccall unsafe "uih_macos_control_set_enabled"
  c_controlSetEnabled :: Ptr MacControlHandle -> CInt -> IO ()

foreign import ccall unsafe "uih_macos_control_focus"
  c_controlFocus :: Ptr MacWindowHandle -> Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_control_destroy"
  c_controlDestroy :: Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_command_set"
  c_commandSet :: Word64 -> CString -> CString -> CInt -> IO ()

foreign import ccall unsafe "uih_macos_command_remove"
  c_commandRemove :: Word64 -> IO ()
