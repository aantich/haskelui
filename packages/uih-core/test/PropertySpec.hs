{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module PropertySpec (runPropertyTests) where

import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import UIH.Binding
import UIH.Core
  ( Transaction (..)
  , UndoGroup (..)
  , UndoPolicy (..)
  , applyTransaction
  )
import UIH.Property

data Document = Document
  { title :: !Text
  , dirty :: !Bool
  }
  deriving stock (Eq, Generic, Show)

data Settings = Settings
  { fontSize :: !Int
  }
  deriving stock (Eq, Generic, Show)

data Model = Model
  { document :: !Document
  , settings :: !Settings
  , documentPresent :: !Bool
  }
  deriving stock (Eq, Generic, Show)

properties :: Path Model Model
properties = rootPath

documentProperties :: Path Document Document
documentProperties = rootPath

titleProperty :: Property Model Text
titleProperty = fromLens (PropertyId "document.title.explicit") (#document . #title)

documentProperty :: Property Model Document
documentProperty = property (PropertyId "document") #document

documentTitleProperty :: Property Document Text
documentTitleProperty = property (PropertyId "title") #title

titleBinding :: Binding Model Text
titleBinding =
  bindWith
    properties.document.title
    [ alsoWrite (const (properties.document.dirty .= True))
    , validateWith nonblank
    , commitPolicy Live
    , undoPolicy (Coalesce (UndoGroup "document-title"))
    , syncPolicy DetectConcurrentChange
    , labelTransaction "Rename document"
    ]

fontSizeBinding :: Binding Model Text
fontSizeBinding =
  bindText
    properties.settings.fontSize
    (textCodec (Text.pack . show) parseInteger)
    [ validateWith validFontSize
    , commitPolicy OnEnterOrBlur
    , undoPolicy (SingleUndo (UndoGroup "font-size"))
    , labelTransaction "Change font size"
    ]

selectedTitle :: OptionalProperty Model Text
selectedTitle =
  optionalProperty
    (PropertyId "selected-document.title")
    (\model -> if model.documentPresent then Just model.document.title else Nothing)
    ( \newTitle model ->
        if model.documentPresent
          then Right model {document = model.document {title = newTitle}}
          else Left (MissingPropertyTarget (PropertyId "selected-document.title"))
    )

runPropertyTests :: IO ()
runPropertyTests = do
  let original = Model (Document "Original" False) (Settings 14) True

  assertEqual "dotted path reads nested authoritative state"
    "Original" (get properties.document.title original)
  assertEqual "explicit generic lenses remain interoperable"
    "Original" (get titleProperty original)

  let rename = properties.document.title .= ("Renamed" :: Text)
      renamed = applyAction rename original
  assertEqual "dotted assignment updates nested state" "Renamed" renamed.document.title
  assertEqual "dotted assignment derives inspectable identity"
    [PropertyId "document.title"] (actionPropertyIds rename)
  assertEqual "dotted paths expose the same identity directly"
    (PropertyId "document.title") (propertyId properties.document.title)
  assertEqual "dotted assignment derives an action description"
    "Set document.title" (actionDescription rename)

  let composed = documentProperty >. documentTitleProperty
  assertEqual "explicit property composition qualifies identity"
    [PropertyId "document.title"]
    (actionPropertyIds (composed .= ("Composed" :: Text)))

  let changed = applyAction (modify properties.settings.fontSize (+ 2)) original
  assertEqual "modify applies atomically" 16 changed.settings.fontSize

  assertEqual "optional property reads a present target"
    (Just "Original") (getOptional selectedTitle original)
  selectedRenamed <- expectRight "optional property updates a present target"
    (setOptional selectedTitle "Selected" original)
  assertEqual "optional property update changed its target"
    (Just "Selected") (getOptional selectedTitle selectedRenamed)
  assertEqual "optional property exposes missing-target failure"
    (Left (MissingPropertyTarget (PropertyId "selected-document.title")))
    (setOptional selectedTitle "Missing" original {documentPresent = False})

  assertEqual "binding reads the authoritative property"
    "Original" (readBinding titleBinding original)
  assertEqual "binding retains its property identity"
    (Just (PropertyId "document.title")) (bindingPropertyId titleBinding)
  assertEqual "binding exposes declared commit policy" Live (bindingCommitPolicy titleBinding)

  case editBinding original InputChanged titleBinding "New title" of
    EditCommitted _ transactionValue -> do
      let edited = applyTransaction transactionValue original
      assertEqual "binding commit writes the property" "New title" edited.document.title
      assertEqual "binding can atomically update dirty state" True edited.document.dirty
      assertEqual "binding transaction retains every touched property"
        [PropertyId "document.dirty", PropertyId "document.title"]
        (actionPropertyIds transactionValue.transactionAction)
      assertEqual "binding retains undo policy"
        (Coalesce (UndoGroup "document-title")) transactionValue.transactionUndo
      assertEqual "binding retains transaction label"
        (Just "Rename document") transactionValue.transactionDescription
    DraftStaged _ -> error "live binding unexpectedly staged a valid draft"
    DraftInvalid _ issues -> error ("valid title rejected: " <> show issues)

  case editBinding original InputChanged titleBinding "   " of
    DraftInvalid draft issues -> do
      assertEqual "invalid binding decision preserves exact draft" "   " draft
      assertEqual "validator reports its typed issue" [BindingIssue "title.blank" "Title cannot be blank"] issues
    DraftStaged _ -> error "blank title unexpectedly staged"
    EditCommitted {} -> error "blank title unexpectedly committed"

  assertEqual "formatted binding reads model value as text"
    "14" (readBinding fontSizeBinding original)
  case editBinding original InputChanged fontSizeBinding "18" of
    DraftStaged draft -> assertEqual "non-live binding stages a valid draft" "18" draft
    DraftInvalid _ issues -> error ("valid font size rejected: " <> show issues)
    EditCommitted {} -> error "OnEnterOrBlur binding committed during typing"
  case editBinding original InputChanged fontSizeBinding "18x" of
    DraftInvalid draft _ -> assertEqual "parse failure preserves draft" "18x" draft
    DraftStaged _ -> error "unparseable draft staged"
    EditCommitted {} -> error "unparseable draft committed"
  case editBinding original EnterPressed fontSizeBinding "18" of
    EditCommitted _ transactionValue ->
      assertEqual "enter commits parsed authoritative value"
        18 (applyTransaction transactionValue original).settings.fontSize
    DraftStaged _ -> error "enter did not commit a valid draft"
    DraftInvalid _ issues -> error ("valid enter draft rejected: " <> show issues)

  let numericControlBinding =
        bindWithCodec
          properties.settings.fontSize
          (codec fromIntegral (Right . round))
          []
  assertEqual "generic codecs map authoritative and control value types"
    (14 :: Double) (readBinding numericControlBinding original)
  case editBinding original InputChanged numericControlBinding 22.0 of
    EditCommitted _ transactionValue ->
      assertEqual "generic codec commits decoded model value"
        22 (applyTransaction transactionValue original).settings.fontSize
    _ -> error "generic numeric codec did not commit"

  let baseline = captureDraftBaseline titleBinding original
      remote = original {document = original.document {title = "Remote"}}
  assertEqual "pristine draft refreshes after authoritative update"
    (DraftRefreshed "Remote") (reconcileDraft baseline remote "Original")
  assertEqual "concurrent local and authoritative edits conflict"
    (DraftConflictDetected (BindingConflict "Original" "Local" "Remote"))
    (reconcileDraft baseline remote "Local")
  assertEqual "equal local and authoritative edits converge without conflict"
    (DraftPreserved "Remote")
    (reconcileDraft baseline remote "Remote")

  let preserveBinding =
        bindWith
          properties.document.title
          [syncPolicy PreserveLocalDraft]
      preserveBaseline = captureDraftBaseline preserveBinding original
  assertEqual "preserve policy never replaces the local draft"
    (DraftPreserved "Original")
    (reconcileDraft preserveBaseline remote "Original")

  let caseInsensitive =
        bindWith
          properties.document.title
          [equivalentWith (\left right -> Text.toCaseFold left == Text.toCaseFold right)]
      equivalentBaseline = captureDraftBaseline caseInsensitive original
      capitalizationOnly = original {document = original.document {title = "ORIGINAL"}}
  assertEqual "custom equivalence controls external-update comparison"
    (DraftPreserved "Original")
    (reconcileDraft equivalentBaseline capitalizationOnly "Original")

  let controlledBinding =
        controlled 14 (properties.settings.fontSize .=)
  assertEqual "callback-style controlled binding reads captured value"
    14 (readBinding controlledBinding original)
  case editBinding original InputChanged controlledBinding 20 of
    EditCommitted _ transactionValue ->
      assertEqual "controlled binding writes through its callback"
        20 (applyTransaction transactionValue original).settings.fontSize
    _ -> error "controlled live binding did not commit"

  let modelValidatedBinding =
        bindWith
          properties.document.title
          [ validateWithModel
              (\current _ ->
                if current.documentPresent
                  then Right ()
                  else Left (BindingIssue "document.missing" "The document is no longer available")
              )
          ]
      missingDocument = original {documentPresent = False}
  assertEqual "model-aware validation can enforce cross-model constraints"
    [BindingIssue "document.missing" "The document is no longer available"]
    (validateBinding missingDocument modelValidatedBinding "Updated")

  assertEqual "child paths can be defined independently"
    "Original" (get documentProperties.title original.document)

  putStrLn "uih-property: total paths, actions, bindings, validation, and draft synchronization passed"

nonblank :: Text -> Either BindingIssue ()
nonblank candidate
  | Text.null (Text.strip candidate) =
      Left (BindingIssue "title.blank" "Title cannot be blank")
  | otherwise = Right ()

parseInteger :: Text -> Either BindingIssue Int
parseInteger candidate =
  case reads (Text.unpack candidate) of
    [(value, "")] -> Right value
    _ -> Left (BindingIssue "integer.invalid" "Enter a whole number")

validFontSize :: Int -> Either BindingIssue ()
validFontSize value
  | value >= 8 && value <= 96 = Right ()
  | otherwise = Left (BindingIssue "font-size.range" "Font size must be between 8 and 96")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise = error (label <> ": expected " <> show expected <> ", got " <> show actual)

expectRight :: Show problem => String -> Either problem value -> IO value
expectRight _ (Right value) = pure value
expectRight label (Left problem) = error (label <> ": unexpected " <> show problem)
