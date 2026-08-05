{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module UIH.Backend.AppKit.Internal.FFI
  ( CDebugCounters (..)
  , CMacRect (..)
  , CTextStyle
  , EventCallback
  , MacControlHandle
  , MacWindowHandle
  , c_commandRemove
  , c_commandSet
  , c_controlDestroy
  , c_controlFocus
  , c_controlSetNextKey
  , c_controlSetEnabled
  , c_controlSetFrame
  , c_controlSetText
  , c_textEditorApplyStyle
  , c_textEditorBeginPresentation
  , c_textEditorEndPresentation
  , c_textEditorSetBaseStyle
  , c_createButton
  , c_createLabel
  , c_createTextField
  , c_createTextEditor
  , c_createWindow
  , c_debugCounters
  , c_initialize
  , c_openTextFiles
  , c_run
  , c_shutdown
  , c_stop
  , c_testLastFailure
  , c_testScheduleVerticalScript
  , c_testScheduleTextEditorScript
  , c_versionMajor
  , c_versionMinor
  , c_versionPatch
  , c_windowDestroy
  , c_windowSetTitle
  , c_windowShow
  , makeEventCallback
  , withCTextStyle
  , withMacRect
  ) where

import Data.Bits ((.|.))
import qualified Data.ByteString as ByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word32, Word64)
import Foreign
  ( FunPtr
  , Ptr
  , Storable (..)
  , alloca
  , pokeByteOff
  , peekByteOff
  )
import Foreign.C
  ( CDouble (..)
  , CInt (..)
  , CString
  )
import UIH.Core
  ( Color (..)
  , FontFamily (..)
  , FontSlant (..)
  , FontWeight (..)
  , Rect (..)
  , TextStyle (..)
  , UnderlineStyle (..)
  )

data MacWindowHandle
data MacControlHandle

data CDebugCounters = CDebugCounters
  !CInt
  !CInt
  !CInt
  !CInt
  !CInt
  !CInt
  deriving stock (Eq, Show)

instance Storable CDebugCounters where
  sizeOf _ = 24
  alignment _ = alignment (undefined :: CInt)
  peek pointer =
    CDebugCounters
      <$> peekByteOff pointer 0
      <*> peekByteOff pointer 4
      <*> peekByteOff pointer 8
      <*> peekByteOff pointer 12
      <*> peekByteOff pointer 16
      <*> peekByteOff pointer 20
  poke pointer (CDebugCounters windows controls targets delegates callbacks failures) = do
    pokeByteOff pointer 0 windows
    pokeByteOff pointer 4 controls
    pokeByteOff pointer 8 targets
    pokeByteOff pointer 12 delegates
    pokeByteOff pointer 16 callbacks
    pokeByteOff pointer 20 failures

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

data CTextStyle = CTextStyle
  { cStyleFields :: !Word32
  , cStyleFamilyKind :: !CInt
  , cStyleWeight :: !CInt
  , cStyleSlant :: !CInt
  , cStyleUnderline :: !CInt
  , cStyleStrikethrough :: !CInt
  , cStyleForegroundRed :: !CDouble
  , cStyleForegroundGreen :: !CDouble
  , cStyleForegroundBlue :: !CDouble
  , cStyleForegroundAlpha :: !CDouble
  , cStyleBackgroundRed :: !CDouble
  , cStyleBackgroundGreen :: !CDouble
  , cStyleBackgroundBlue :: !CDouble
  , cStyleBackgroundAlpha :: !CDouble
  , cStyleFontSize :: !CDouble
  , cStyleLetterSpacing :: !CDouble
  , cStyleBaselineOffset :: !CDouble
  , cStyleFamilyName :: !CString
  }

instance Storable CTextStyle where
  sizeOf _ = 120
  alignment _ = alignment (undefined :: Ptr ())
  peek pointer =
    CTextStyle
      <$> peekByteOff pointer 0
      <*> peekByteOff pointer 4
      <*> peekByteOff pointer 8
      <*> peekByteOff pointer 12
      <*> peekByteOff pointer 16
      <*> peekByteOff pointer 20
      <*> peekByteOff pointer 24
      <*> peekByteOff pointer 32
      <*> peekByteOff pointer 40
      <*> peekByteOff pointer 48
      <*> peekByteOff pointer 56
      <*> peekByteOff pointer 64
      <*> peekByteOff pointer 72
      <*> peekByteOff pointer 80
      <*> peekByteOff pointer 88
      <*> peekByteOff pointer 96
      <*> peekByteOff pointer 104
      <*> peekByteOff pointer 112
  poke pointer style = do
    pokeByteOff pointer 0 style.cStyleFields
    pokeByteOff pointer 4 style.cStyleFamilyKind
    pokeByteOff pointer 8 style.cStyleWeight
    pokeByteOff pointer 12 style.cStyleSlant
    pokeByteOff pointer 16 style.cStyleUnderline
    pokeByteOff pointer 20 style.cStyleStrikethrough
    pokeByteOff pointer 24 style.cStyleForegroundRed
    pokeByteOff pointer 32 style.cStyleForegroundGreen
    pokeByteOff pointer 40 style.cStyleForegroundBlue
    pokeByteOff pointer 48 style.cStyleForegroundAlpha
    pokeByteOff pointer 56 style.cStyleBackgroundRed
    pokeByteOff pointer 64 style.cStyleBackgroundGreen
    pokeByteOff pointer 72 style.cStyleBackgroundBlue
    pokeByteOff pointer 80 style.cStyleBackgroundAlpha
    pokeByteOff pointer 88 style.cStyleFontSize
    pokeByteOff pointer 96 style.cStyleLetterSpacing
    pokeByteOff pointer 104 style.cStyleBaselineOffset
    pokeByteOff pointer 112 style.cStyleFamilyName

withCTextStyle :: TextStyle -> (Ptr CTextStyle -> IO result) -> IO result
withCTextStyle style use =
  ByteString.useAsCString (TextEncoding.encodeUtf8 (familyName style)) $ \familyPointer ->
    alloca $ \stylePointer -> do
      poke stylePointer (encodeTextStyle familyPointer style)
      use stylePointer

encodeTextStyle :: CString -> TextStyle -> CTextStyle
encodeTextStyle familyPointer style =
  CTextStyle
    { cStyleFields =
        optionalField 0x001 style.textForeground
          .|. optionalField 0x002 style.textBackground
          .|. optionalField 0x004 style.textFontFamily
          .|. optionalField 0x008 style.textFontSize
          .|. optionalField 0x010 style.textFontWeight
          .|. optionalField 0x020 style.textFontSlant
          .|. optionalField 0x040 style.textUnderline
          .|. optionalField 0x080 style.textStrikethrough
          .|. optionalField 0x100 style.textLetterSpacing
          .|. optionalField 0x200 style.textBaselineOffset
    , cStyleFamilyKind = maybe 0 encodeFontFamily style.textFontFamily
    , cStyleWeight = maybe 0 encodeFontWeight style.textFontWeight
    , cStyleSlant = maybe 0 encodeFontSlant style.textFontSlant
    , cStyleUnderline = maybe 0 encodeUnderline style.textUnderline
    , cStyleStrikethrough = maybe 0 booleanInt style.textStrikethrough
    , cStyleForegroundRed = realToFrac foreground.colorRed
    , cStyleForegroundGreen = realToFrac foreground.colorGreen
    , cStyleForegroundBlue = realToFrac foreground.colorBlue
    , cStyleForegroundAlpha = realToFrac foreground.colorAlpha
    , cStyleBackgroundRed = realToFrac background.colorRed
    , cStyleBackgroundGreen = realToFrac background.colorGreen
    , cStyleBackgroundBlue = realToFrac background.colorBlue
    , cStyleBackgroundAlpha = realToFrac background.colorAlpha
    , cStyleFontSize = realToFrac (fromMaybe 0 style.textFontSize)
    , cStyleLetterSpacing = realToFrac (fromMaybe 0 style.textLetterSpacing)
    , cStyleBaselineOffset = realToFrac (fromMaybe 0 style.textBaselineOffset)
    , cStyleFamilyName = familyPointer
    }
  where
    foreground = fromMaybe transparent style.textForeground
    background = fromMaybe transparent style.textBackground
    transparent = RGBA 0 0 0 0

familyName :: TextStyle -> Text
familyName style =
  case style.textFontFamily of
    Just (NamedFont name) -> name
    _ -> ""

optionalField :: Word32 -> Maybe value -> Word32
optionalField bit = maybe 0 (const bit)

encodeFontFamily :: FontFamily -> CInt
encodeFontFamily SystemFont = 1
encodeFontFamily MonospaceFont = 2
encodeFontFamily (NamedFont _) = 3

encodeFontWeight :: FontWeight -> CInt
encodeFontWeight Thin = 100
encodeFontWeight ExtraLight = 200
encodeFontWeight Light = 300
encodeFontWeight Regular = 400
encodeFontWeight Medium = 500
encodeFontWeight SemiBold = 600
encodeFontWeight Bold = 700
encodeFontWeight ExtraBold = 800
encodeFontWeight Black = 900

encodeFontSlant :: FontSlant -> CInt
encodeFontSlant Upright = 1
encodeFontSlant Italic = 2
encodeFontSlant Oblique = 3

encodeUnderline :: UnderlineStyle -> CInt
encodeUnderline UnderlineNone = 0
encodeUnderline UnderlineSingle = 1
encodeUnderline UnderlineDouble = 2
encodeUnderline UnderlineThick = 3
encodeUnderline UnderlineDotted = 4
encodeUnderline UnderlineDashed = 5
encodeUnderline UnderlineWavy = 6

booleanInt :: Bool -> CInt
booleanInt True = 1
booleanInt False = 0

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

foreign import ccall unsafe "uih_macos_text_editor_create"
  c_createTextEditor :: Ptr MacWindowHandle -> Word64 -> CString -> Ptr CMacRect -> IO (Ptr MacControlHandle)

foreign import ccall unsafe "uih_macos_control_set_text"
  c_controlSetText :: Ptr MacControlHandle -> CString -> IO ()

foreign import ccall unsafe "uih_macos_text_editor_begin_presentation"
  c_textEditorBeginPresentation :: Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_text_editor_set_base_style"
  c_textEditorSetBaseStyle :: Ptr MacControlHandle -> Ptr CTextStyle -> IO ()

foreign import ccall unsafe "uih_macos_text_editor_apply_style"
  c_textEditorApplyStyle :: Ptr MacControlHandle -> Word64 -> Word64 -> Ptr CTextStyle -> IO CInt

foreign import ccall unsafe "uih_macos_text_editor_end_presentation"
  c_textEditorEndPresentation :: Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_control_set_frame"
  c_controlSetFrame :: Ptr MacControlHandle -> Ptr CMacRect -> IO ()

foreign import ccall unsafe "uih_macos_control_set_enabled"
  c_controlSetEnabled :: Ptr MacControlHandle -> CInt -> IO ()

foreign import ccall unsafe "uih_macos_control_focus"
  c_controlFocus :: Ptr MacWindowHandle -> Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_control_set_next_key"
  c_controlSetNextKey :: Ptr MacControlHandle -> Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_control_destroy"
  c_controlDestroy :: Ptr MacControlHandle -> IO ()

foreign import ccall unsafe "uih_macos_command_set"
  c_commandSet :: Word64 -> CString -> CString -> CInt -> IO ()

foreign import ccall unsafe "uih_macos_command_remove"
  c_commandRemove :: Word64 -> IO ()

foreign import ccall unsafe "uih_macos_open_text_files"
  c_openTextFiles :: IO ()

foreign import ccall unsafe "uih_macos_debug_counters"
  c_debugCounters :: Ptr CDebugCounters -> IO ()

foreign import ccall unsafe "uih_macos_test_last_failure"
  c_testLastFailure :: IO CString

foreign import ccall unsafe "uih_macos_test_schedule_vertical_script"
  c_testScheduleVerticalScript :: Word64 -> Word64 -> Word64 -> Word64 -> IO ()

foreign import ccall unsafe "uih_macos_test_schedule_text_editor_script"
  c_testScheduleTextEditorScript :: Word64 -> Word64 -> Word64 -> IO ()
