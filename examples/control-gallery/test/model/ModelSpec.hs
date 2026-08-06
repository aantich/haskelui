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
  assert "the semantic native-table fixture is declared" (any isNativeTableFixture flattened)
  assert "row-based gallery controls defer to the platform row-size preference"
    (all usesPlatformRows (filter isRowCollection flattened))
  case filter isNativeTableFixture flattened of
    TableView table : _ -> do
      assert "an explicit fixed row height is accepted"
        (validateControlCatalog [TableView table {collectionControlRowSizing = FixedRows 31}] == [])
      assert "an invalid fixed row height is rejected"
        (not (null (validateControlCatalog [TableView table {collectionControlRowSizing = FixedRows 0}])))
    _ -> error "native table fixture disappeared"
  assert "both semantic and portable-layout containers are declared"
    (any isContainer flattened && any isLayoutContainer flattened)
  assert "every semantic container strategy is declared"
    (containerKinds flattened == [True, True, True, True, True, True, True])

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

isNativeTableFixture :: Control -> Bool
isNativeTableFixture (TableView spec) = spec.collectionControlKey == ElementKey 304
isNativeTableFixture _ = False

isRowCollection :: Control -> Bool
isRowCollection ListView {} = True
isRowCollection TreeView {} = True
isRowCollection TableView {} = True
isRowCollection NavigationSidebar {} = True
isRowCollection _ = False

usesPlatformRows :: Control -> Bool
usesPlatformRows (ListView spec) = spec.collectionControlRowSizing == PlatformDefaultRows
usesPlatformRows (TreeView spec) = spec.collectionControlRowSizing == PlatformDefaultRows
usesPlatformRows (TableView spec) = spec.collectionControlRowSizing == PlatformDefaultRows
usesPlatformRows (NavigationSidebar spec) = spec.collectionControlRowSizing == PlatformDefaultRows
usesPlatformRows _ = False

isContainer :: Control -> Bool
isContainer Container {} = True
isContainer _ = False

isLayoutContainer :: Control -> Bool
isLayoutContainer LayoutContainer {} = True
isLayoutContainer _ = False

containerKinds :: [Control] -> [Bool]
containerKinds controls =
  [ any isStack controls
  , any isGrid controls
  , any isOverlay controls
  , any isCanvas controls
  , any isGroup controls
  , any isScroll controls
  , any isDisclosure controls
  ]
  where
    isStack (Container spec) = case spec.containerKind of StackContainer {} -> True; _ -> False
    isStack _ = False
    isGrid (Container spec) = case spec.containerKind of GridContainer {} -> True; _ -> False
    isGrid _ = False
    isOverlay (Container spec) = spec.containerKind == OverlayContainer
    isOverlay _ = False
    isCanvas (Container spec) = spec.containerKind == CanvasContainer
    isCanvas _ = False
    isGroup (Container spec) = case spec.containerKind of GroupContainer {} -> True; _ -> False
    isGroup _ = False
    isScroll (Container spec) = spec.containerKind == ScrollContainer
    isScroll _ = False
    isDisclosure (Container spec) = case spec.containerKind of DisclosureContainer {} -> True; _ -> False
    isDisclosure _ = False

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")
