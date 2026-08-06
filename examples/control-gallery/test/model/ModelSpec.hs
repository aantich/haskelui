{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List (nub, sort)
import Example.ControlGallery
import UIH.Backend.Headless (newHeadlessBackend)
import UIH.Core
import UIH.Runtime (runApp)

main :: IO ()
main = do
  let controls = galleryControls initialModel
      flattened = flattenControls controls
      keys = fmap controlKey flattened
      kinds = sort (nub (galleryCatalogKinds initialModel))
  assert "every catalog kind is declared" (kinds == [minBound .. maxBound])
  assert "all control identities are unique" (length keys == length (nub keys))
  assert "the complete gallery validates" (validateControlCatalog controls == [])
  assert "legacy controls remain represented" (legacyKinds flattened == [True, True, True, True])

  let textModel = update (TextChanged (ElementKey 205) "native edit") initialModel
      toggleModel = update (ToggleChanged (ElementKey 108) ToggleOff) initialModel
      pageModel = update (ChoiceChanged rootTabKey (Just (ChoiceKey 9204))) initialModel
      dialogModel = update (CommandInvoked (CommandId 9102)) initialModel
      collapsedModel =
        update (CollectionExpansionChanged (ElementKey 303) (CollectionItemKey 1) False) initialModel
      closedModel = update (WindowCloseRequested galleryWindowKey) initialModel
  assert "text event updates authoritative text" (textModel.galleryText == "native edit")
  assert "typed Boolean event updates authoritative toggle" (toggleModel.galleryToggle == ToggleOff)
  assert "ordinary tab selection is model-owned" (pageModel.galleryPage == Just (ChoiceKey 9204))
  assert "dialog visibility is desired state" dialogModel.galleryDialogVisible
  assert "tree expansion is authoritative model state"
    (CollectionItemKey 1 `notElem` collapsedModel.galleryExpandedItems)
  assert "window close removes the only window" (null (renderGallery closedModel).appWindows)

  (backend, latestView) <- newHeadlessBackend
  runApp backend application
  rendered <- latestView
  case rendered of
    Just (AppView [WindowSpec {windowControls = renderedControls}] commands) -> do
      assert "headless backend retains the complete semantic tree"
        (length (flattenControls renderedControls) == length flattened)
      assert "headless backend retains shared commands" (length commands == 7)
    _ -> error "headless gallery did not render one flat window"

  putStrLn
    ( "control gallery: " <> show (length flattened)
        <> " controls cover all " <> show (length kinds) <> " catalog kinds"
    )
  where
    update event model = applyTransaction (application.appHandleEvent event model) model

legacyKinds :: [Control] -> [Bool]
legacyKinds controls =
  [ any isLabel controls
  , any isButton controls
  , any isTextField controls
  , any isTextEditor controls
  ]
  where
    isLabel Label {} = True
    isLabel _ = False
    isButton Button {} = True
    isButton _ = False
    isTextField TextField {} = True
    isTextField _ = False
    isTextEditor TextEditor {} = True
    isTextEditor _ = False

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")
