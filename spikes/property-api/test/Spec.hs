{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import UIH.Property.Spike

main :: IO ()
main = do
  let original =
        Model
          { document = Document {title = "Original", body = "Body"}
          , count = 1
          , documents = Map.singleton 7 (Document "Seven" "Body seven")
          , selectedDocument = Just 7
          }

  assertEqual
    "generic overloaded-label lenses compose inside Property"
    "Original"
    (get documentTitle original)
  assertEqual
    "the proposed fromLens-style expression compiles directly"
    "Original"
    (get directDocumentTitle original)

  let renamed = applyAction (documentTitle .= "Renamed") original
  assertEqual "property assignment updates nested model state" "Renamed" renamed.document.title
  assertEqual
    "property assignment is inspectable"
    "SetModel document.title"
    (describeAction (documentTitle .= "Renamed"))

  let incremented = applyAction (modify (property (PropertyId "count") #count) (+ 1)) original
  assertEqual "modify is interpreted atomically" 2 incremented.count

  let dottedAction = properties.document.title .= ("Dotted" :: Text)
      dotted = applyAction dottedAction original
  assertEqual "record-dot paths update through a generated lens" "Dotted" dotted.document.title
  assertEqual "record-dot paths derive a qualified identity" "SetModel document.title" (describeAction dottedAction)

  let hover = elementProperty "window.editor.hovered"
      elementAction = setElement hover True :: Action Model
  assertEqual "element properties use an ownership-explicit operation" "SetElement window.editor.hovered" (describeAction elementAction)
  assertEqual "element assignment does not mutate the application model" original (applyAction elementAction original)

  assertEqual "optional property reads an existing keyed target" (Just "Seven") (getOptional selectedDocumentTitle original)
  selectedRenamed <- expectRight "optional property updates an existing target" (assignOptional selectedDocumentTitle "Selected" original)
  assertEqual "optional update changed the selected document" (Just "Selected") (getOptional selectedDocumentTitle selectedRenamed)

  let missing = original {selectedDocument = Just 99}
  assertEqual
    "optional property reports a missing target"
    (Left (MissingTarget (PropertyId "documents.selected.title")))
    (assignOptional selectedDocumentTitle "Missing" missing)

  putStrLn "property API spike: all assertions passed"

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual label expected actual
  | expected == actual = pure ()
  | otherwise =
      error
        ( label
            <> "\nexpected: "
            <> show expected
            <> "\n but got: "
            <> show actual
        )

expectRight :: Show error => String -> Either error value -> IO value
expectRight _ (Right value) = pure value
expectRight label (Left problem) = error (label <> "\nunexpected error: " <> show problem)
