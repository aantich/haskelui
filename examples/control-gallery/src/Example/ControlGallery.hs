{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Example.ControlGallery
  ( GalleryModel (..)
  , application
  , collectionApplication
  , galleryCatalogKinds
  , galleryControls
  , galleryWindowKey
  , initialModel
  , layoutApplication
  , renderGallery
  , rootTabKey
  ) where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import HaskeLUI.Core

data GalleryModel = GalleryModel
  { galleryWindowOpen :: !Bool
  , galleryText :: !Text
  , galleryRevision :: !TextRevision
  , galleryToggle :: !ToggleValue
  , galleryChoice :: !(Maybe ChoiceKey)
  , galleryNumber :: !Double
  , galleryDate :: !DateComponents
  , galleryTime :: !TimeComponents
  , galleryColor :: !Color
  , gallerySelection :: ![CollectionItemKey]
  , galleryExpandedItems :: ![CollectionItemKey]
  , galleryPage :: !(Maybe ChoiceKey)
  , galleryDisclosureExpanded :: !Bool
  , galleryDialogVisible :: !Bool
  , galleryAlertVisible :: !Bool
  , galleryPopoverVisible :: !Bool
  , galleryLastEvent :: !Text
  }
  deriving stock (Eq, Show)

galleryWindowKey :: WindowKey
galleryWindowKey = WindowKey 9000

rootTabKey :: ElementKey
rootTabKey = ElementKey 9001

generalCommand, closeCommand, dialogCommand, alertCommand, popoverCommand :: CommandId
generalCommand = CommandId 9100
closeCommand = CommandId 9101
dialogCommand = CommandId 9102
alertCommand = CommandId 9103
popoverCommand = CommandId 9104

secondaryCommand, destructiveCommand :: CommandId
secondaryCommand = CommandId 9105
destructiveCommand = CommandId 9106

contentPage, inputPage, collectionPage, shellPage, containerPage, layoutPage :: ChoiceKey
contentPage = ChoiceKey 9201
inputPage = ChoiceKey 9202
collectionPage = ChoiceKey 9203
shellPage = ChoiceKey 9204
containerPage = ChoiceKey 9205
layoutPage = ChoiceKey 9206

initialModel :: GalleryModel
initialModel =
  GalleryModel
    { galleryWindowOpen = True
    , galleryText = "Edit me in any text control"
    , galleryRevision = TextRevision 1
    , galleryToggle = ToggleOn
    , galleryChoice = Just (ChoiceKey 1)
    , galleryNumber = 4
    , galleryDate = DateComponents 2026 8 6
    , galleryTime = TimeComponents 14 30 0
    , galleryColor = RGBA 0.18 0.48 0.92 1
    , gallerySelection = [CollectionItemKey 2]
    , galleryExpandedItems = [CollectionItemKey 1]
    , galleryPage = Just contentPage
    , galleryDisclosureExpanded = True
    , galleryDialogVisible = False
    , galleryAlertVisible = False
    , galleryPopoverVisible = False
    , galleryLastEvent = "Ready — interact with any control"
    }

application :: App GalleryModel
application =
  App
    { appInitialModel = initialModel
    , appInitialEffects = []
    , appInitialCommands = []
    , appServices = []
    , appSubscriptions = const []
    , appView = renderGallery
    , appHandleEvent = handleGalleryEvent
    }

-- | The same exhaustive gallery with the portable-layout page selected. This
-- is useful for deterministic visual inspection without automating a tab
-- click in the native window.
layoutApplication :: App GalleryModel
layoutApplication =
  application
    { appInitialModel = initialModel {galleryPage = Just layoutPage}
    , appInitialEffects = []
    }

-- | The exhaustive gallery with the native collection-control page selected.
-- This makes the otherwise visually similar list, grid, tree, table, repeater,
-- and navigation peers easy to inspect side by side.
collectionApplication :: App GalleryModel
collectionApplication =
  application
    { appInitialModel = initialModel {galleryPage = Just collectionPage}
    , appInitialEffects = []
    }

renderGallery :: GalleryModel -> AppView
renderGallery model =
  AppView
    { appWindows = [galleryWindow model | model.galleryWindowOpen]
    , appCommands = galleryCommands
    }

galleryWindow :: GalleryModel -> WindowSpec
galleryWindow model =
  WindowSpec
    { windowKey = galleryWindowKey
    , windowTitle = "HaskeLUI Core Control Gallery"
    , windowFrame = Rect 70 70 1320 900
    , windowControls = galleryControls model
    }

galleryControls :: GalleryModel -> [Control]
galleryControls model =
  [ galleryTabs model
  , Label
      (ElementKey 9002)
      (Rect 18 14 1040 24)
      ("Last event: " <> model.galleryLastEvent)
  , Button (ElementKey 9003) (Rect 1165 9 130 32) "Close Gallery" closeCommand True
  ]

galleryCatalogKinds :: GalleryModel -> [CatalogControlKind]
galleryCatalogKinds = mapMaybe controlCatalogKind . flattenControls . galleryControls

galleryTabs :: GalleryModel -> Control
galleryTabs model =
  TabView
    TabViewSpec
      { tabViewKey = rootTabKey
      , tabViewFrame = Rect 14 52 1290 832
      , tabViewSelected = model.galleryPage
      , tabViewPages =
          [ TabPageSpec contentPage "Content & commands" (contentControls model)
          , TabPageSpec inputPage "Text & values" (inputControls model)
          , TabPageSpec collectionPage "Collections & navigation" (collectionControls model)
          , TabPageSpec shellPage "Shell & feedback" (shellControls model)
          , TabPageSpec containerPage "Arbitrary-child containers" (containerControls model)
          , TabPageSpec layoutPage "Portable layout lab" (layoutControls model)
          ]
      }

contentControls :: GalleryModel -> [Control]
contentControls model =
  [ Label (ElementKey 100) (Rect 18 748 400 24) "Legacy Label and Button"
  , Button (ElementKey 101) (Rect 18 702 150 34) "Legacy Button" generalCommand True
  , RichText
      RichTextSpec
        { richTextKey = ElementKey 102
        , richTextFrame = Rect 190 690 430 58
        , richTextValue =
            attributedTextFromRuns
              [ TextRun "Rich text: " (mempty {textFontWeight = Just Bold})
              , TextRun "color" (mempty {textForeground = Just (RGBA 0.85 0.18 0.2 1)})
              , TextRun ", size" (mempty {textFontSize = Just 20})
              , TextRun ", italic" (mempty {textFontSlant = Just Italic})
              ]
        }
  , Image (imageSpec 103 (Rect 650 684 72 72) (SystemSymbol "photo") "System image")
  , Icon (imageSpec 104 (Rect 742 700 42 42) (SystemSymbol "star.fill") "Star icon")
  , Separator (ElementKey 105) (Rect 18 668 1230 1)
  , RepeatButton (actionSpec 106 (Rect 18 610 160 34) "Repeat button" (Just (SystemSymbol "repeat")))
  , ToggleButton (toggleSpec 107 (Rect 194 610 150 34) "Toggle button" model.galleryToggle)
  , CheckBox (toggleSpec 108 (Rect 360 610 150 34) "Checkbox" model.galleryToggle)
  , Switch (toggleSpec 109 (Rect 526 610 120 34) "Switch" model.galleryToggle)
  , Link (actionSpec 110 (Rect 670 610 180 34) "Native link" Nothing)
  , RadioGroup (choiceSpec 111 (Rect 18 510 500 70) model.galleryChoice)
  , SegmentedChoice (choiceSpec 112 (Rect 540 530 420 34) model.galleryChoice)
  , MenuButton (choiceSpec 113 (Rect 980 530 220 34) model.galleryChoice)
  , SplitButton (splitSpec 114 (Rect 18 446 230 36) "Split button" Nothing)
  , ToggleSplitButton
      (splitSpec 115 (Rect 270 446 250 36) "Toggle split button" (Just (model.galleryToggle /= ToggleOff)))
  , Badge
      MessageControlSpec
        { messageControlKey = ElementKey 116
        , messageControlFrame = Rect 548 446 170 36
        , messageControlTitle = "Portable badge"
        , messageControlMessage = "Compact status feedback"
        }
  ]

inputControls :: GalleryModel -> [Control]
inputControls model =
  [ Label (ElementKey 200) (Rect 18 748 420 24) "Legacy and catalog text editors share one model value"
  , TextField (ElementKey 201) (Rect 18 704 380 28) model.galleryText "Legacy text field" False
  , TextEditor (editorSpec 202 (Rect 18 566 590 120) model False)
  , TextArea (textInputSpec 203 (Rect 630 566 590 120) model "Plain multiline text")
  , RichTextEditor (editorSpec 204 (Rect 18 408 590 130) model False)
  , SecureField (textInputSpec 205 (Rect 630 498 280 30) model "Secure field")
  , SearchField (textInputSpec 206 (Rect 930 498 290 30) model "Search")
  , SuggestField (suggestInputSpec 207 (Rect 630 452 280 30) model "Suggest field")
  , EditableComboBox (suggestInputSpec 208 (Rect 930 452 290 30) model "Editable combo")
  , ChoicePicker (choiceSpec 209 (Rect 630 408 280 30) model.galleryChoice)
  , NumberField (numericSpec 210 (Rect 18 344 180 34) model.galleryNumber 0 10 1)
  , Stepper (numericSpec 211 (Rect 218 344 70 34) model.galleryNumber 0 10 1)
  , Slider (numericSpec 212 (Rect 310 344 300 34) model.galleryNumber 0 10 1)
  , Rating (numericSpec 213 (Rect 630 344 240 34) model.galleryNumber 0 5 1)
  , DatePicker (dateSpec 214 (Rect 18 282 240 34) model)
  , TimePicker (timeSpec 215 (Rect 278 282 220 34) model)
  , ColorPicker
      ColorControlSpec
        { colorControlKey = ElementKey 216
        , colorControlFrame = Rect 520 282 80 34
        , colorControlValue = model.galleryColor
        , colorControlEnabled = True
        }
  , CalendarView (dateSpec 217 (Rect 630 140 430 180) model)
  ]

collectionControls :: GalleryModel -> [Control]
collectionControls model =
  [ Label (ElementKey 308) (Rect 18 782 260 20) "Breadcrumb"
  , Breadcrumb
      BreadcrumbSpec
        { breadcrumbKey = ElementKey 300
        , breadcrumbFrame = Rect 18 740 1210 36
        , breadcrumbItems = galleryChoices
        , breadcrumbSelected = model.galleryChoice
        }
  , Label (ElementKey 309) (Rect 18 716 280 20) "ListView — native list"
  , ListView (collectionSpec 301 (Rect 18 430 280 280) model SingleCollectionSelection)
  , Label (ElementKey 310) (Rect 316 716 280 20) "CollectionView — native grid"
  , CollectionView (collectionSpec 302 (Rect 316 430 280 280) model MultipleCollectionSelection)
  , Label (ElementKey 311) (Rect 614 716 280 20) "TreeView — native outline"
  , TreeView (collectionSpec 303 (Rect 614 430 280 280) model SingleCollectionSelection)
  , Label (ElementKey 312) (Rect 912 716 316 20) "TableView — native data table"
  , TableView (collectionSpec 304 (Rect 912 430 316 280) model MultipleCollectionSelection)
  , Label (ElementKey 313) (Rect 18 396 390 20) "ItemRepeater — lightweight collection"
  , ItemRepeater (collectionSpec 305 (Rect 18 100 390 290) model NoCollectionSelection)
  , Label (ElementKey 314) (Rect 428 396 330 20) "NavigationSidebar — native source list"
  , NavigationSidebar (collectionSpec 306 (Rect 428 100 330 290) model SingleCollectionSelection)
  , InlineNotice
      MessageControlSpec
        { messageControlKey = ElementKey 307
        , messageControlFrame = Rect 780 250 448 140
        , messageControlTitle = "Collections preserve stable item keys"
        , messageControlMessage = "Selection, item identity and native virtualization belong to the backend contract."
        }
  ]

shellControls :: GalleryModel -> [Control]
shellControls model =
  [ Label (ElementKey 415) (Rect 18 778 260 20) "Menu surface"
  , MenuBar
      MenuControlSpec
        { menuControlKey = ElementKey 400
        , menuControlFrame = Rect 18 738 720 38
        , menuControlTitle = "Gallery menu"
        , menuControlEntries = galleryMenu
        }
  , Label (ElementKey 416) (Rect 760 778 260 20) "Toolbar surface"
  , Toolbar
      ToolbarSpec
        { toolbarKey = ElementKey 401
        , toolbarFrame = Rect 760 738 468 38
        , toolbarCommands = [generalCommand, secondaryCommand, destructiveCommand]
        }
  , Label (ElementKey 417) (Rect 18 708 260 20) "Context-menu trigger"
  , ContextMenu
      MenuControlSpec
        { menuControlKey = ElementKey 402
        , menuControlFrame = Rect 18 672 260 34
        , menuControlTitle = "Context commands"
        , menuControlEntries = galleryMenu
        }
  , Button (ElementKey 403) (Rect 18 602 180 36) "Show dialog" dialogCommand True
  , Button (ElementKey 404) (Rect 218 602 180 36) "Show alert" alertCommand True
  , Button (ElementKey 405) (Rect 418 602 190 36) "Show popover" popoverCommand True
  , Tooltip
      MessageControlSpec
        { messageControlKey = ElementKey 406
        , messageControlFrame = Rect 650 590 260 60
        , messageControlTitle = "Hover for native tooltip"
        , messageControlMessage = "The same semantic help text is exposed to accessibility."
        }
  , ProgressBar (progressSpec 407 (Rect 18 520 360 20) model.galleryNumber 0 10)
  , ActivityIndicator (ElementKey 408) (Rect 408 498 48 48) True
  , Meter (progressSpec 409 (Rect 486 520 330 20) model.galleryNumber 0 10)
  , Badge
      MessageControlSpec
        { messageControlKey = ElementKey 410
        , messageControlFrame = Rect 846 500 150 42
        , messageControlTitle = "3 updates"
        , messageControlMessage = "Badge detail"
        }
  , InlineNotice
      MessageControlSpec
        { messageControlKey = ElementKey 411
        , messageControlFrame = Rect 18 350 980 110
        , messageControlTitle = "Presentation lifecycle"
        , messageControlMessage = "Presentation is desired state. Native dismissal returns a typed result to pure Haskell update code."
        }
  , Dialog
      PresentationSpec
        { presentationKey = ElementKey 412
        , presentationFrame = Rect 0 0 0 0
        , presentationKind = DialogPresentation
        , presentationTitle = "Portable dialog"
        , presentationMessage = "This sheet is owned by desired Haskell state."
        , presentationVisible = model.galleryDialogVisible
        }
  , Alert
      PresentationSpec
        { presentationKey = ElementKey 413
        , presentationFrame = Rect 0 0 0 0
        , presentationKind = AlertPresentation
        , presentationTitle = "Portable alert"
        , presentationMessage = "AppKit renders NSAlert; Windows will render ContentDialog."
        , presentationVisible = model.galleryAlertVisible
        }
  , Popover
      PresentationSpec
        { presentationKey = ElementKey 414
        , presentationFrame = Rect 0 0 0 0
        , presentationKind = PopoverPresentation (ElementKey 405)
        , presentationTitle = "Portable popover"
        , presentationMessage = "Anchored transient native content."
        , presentationVisible = model.galleryPopoverVisible
        }
  ]

containerControls :: GalleryModel -> [Control]
containerControls model =
  [ Container
      ContainerSpec
        { containerKey = ElementKey 500
        , containerFrame = Rect 18 620 570 130
        , containerKind = StackContainer Horizontal 8
        , containerChildren =
            [ Label (ElementKey 501) (Rect 0 0 160 40) "Arbitrary label child"
            , Button (ElementKey 502) (Rect 0 0 160 40) "Arbitrary button child" generalCommand True
            , Icon (imageSpec 503 (Rect 0 0 40 40) (SystemSymbol "shippingbox.fill") "Box icon")
            ]
        }
  , Container
      ContainerSpec
        { containerKey = ElementKey 510
        , containerFrame = Rect 616 620 612 130
        , containerKind = GridContainer 2 8
        , containerChildren =
            [ Label (ElementKey 511) (Rect 0 0 100 30) "Grid cell A"
            , Button (ElementKey 512) (Rect 0 0 100 30) "Grid cell B" secondaryCommand True
            , CheckBox (toggleSpec 513 (Rect 0 0 160 30) "Grid checkbox" model.galleryToggle)
            , ProgressBar (progressSpec 514 (Rect 0 0 100 20) model.galleryNumber 0 10)
            ]
        }
  , Container
      ContainerSpec
        { containerKey = ElementKey 520
        , containerFrame = Rect 18 430 370 160
        , containerKind = OverlayContainer
        , containerChildren =
            [ Badge (MessageControlSpec (ElementKey 521) (Rect 25 35 250 70) "Overlay base" "First child")
            , Icon (imageSpec 522 (Rect 240 72 34 34) (SystemSymbol "star.fill") "Foreground layer")
            ]
        }
  , Container
      ContainerSpec
        { containerKey = ElementKey 530
        , containerFrame = Rect 418 430 370 160
        , containerKind = CanvasContainer
        , containerChildren =
            [ Icon (imageSpec 531 (Rect 25 70 50 50) (SystemSymbol "circle.fill") "Canvas circle")
            , Label (ElementKey 532) (Rect 110 82 220 24) "Explicit canvas position"
            ]
        }
  , Container
      ContainerSpec
        { containerKey = ElementKey 540
        , containerFrame = Rect 818 430 410 160
        , containerKind = GroupContainer "Semantic group"
        , containerChildren =
            [ Label (ElementKey 541) (Rect 22 70 340 24) "Group accepts any child view"
            , Slider (numericSpec 542 (Rect 22 28 340 28) model.galleryNumber 0 10 1)
            ]
        }
  , Container
      ContainerSpec
        { containerKey = ElementKey 550
        , containerFrame = Rect 18 100 570 290
        , containerKind = ScrollContainer
        , containerChildren =
            [ RichText
                RichTextSpec
                  { richTextKey = ElementKey 551
                  , richTextFrame = Rect 18 440 470 50
                  , richTextValue = attributedTextFromRuns [TextRun "Scrollable arbitrary rich content" mempty]
                  }
            , Button (ElementKey 552) (Rect 18 30 220 36) "Button at document bottom" generalCommand True
            ]
        }
  , Container
      ContainerSpec
        { containerKey = ElementKey 560
        , containerFrame = Rect 616 100 612 290
        , containerKind = DisclosureContainer "Disclosure group" model.galleryDisclosureExpanded
        , containerChildren =
            [ Label (ElementKey 561) (Rect 22 180 500 28) "Retained arbitrary disclosure content"
            , TextField (ElementKey 562) (Rect 22 130 420 30) model.galleryText "Nested legacy field" False
            , Button (ElementKey 563) (Rect 22 72 220 36) "Nested command" generalCommand True
            ]
        }
  ]

layoutControls :: GalleryModel -> [Control]
layoutControls model = [layoutLab model]

layoutLab :: GalleryModel -> Control
layoutLab model =
  LayoutContainer
    LayoutContainerSpec
      { layoutContainerKey = ElementKey 6000
      , layoutContainerFrame = Rect 18 24 1210 748
      , layoutContainerPresentation = ScrollLayoutContainer Vertical
      , layoutContainerEnvironment = defaultLayoutEnvironment
      , layoutContainerLayout =
          LayoutCanvas
            defaultCanvas {canvasContentSize = Just (Size 1170 1220)}
            [ canvas 16 16 552 150 6010
            , canvas 584 16 552 150 6020
            , canvas 16 182 1120 170 6030
            , canvas 16 368 1120 230 6100
            , canvas 16 614 552 180 6040
            , canvas 584 614 552 180 6050
            , canvas 16 810 1120 150 6060
            , canvas 16 976 1120 220 6070
            ]
      , layoutContainerChildren =
          [ flowLayoutExample
          , alignmentLayoutExample
          , gridLayoutExample model
          , overlayLayoutExample
          , wrapLayoutExample
          , splitLayoutExample
          , linedTableLayoutExample
          , adaptiveLayoutExample
          ]
      }
  where
    canvas x y width height key =
      CanvasItem x y (Just width) (Just height) 0 (LayoutLeaf (ElementKey key))

flowLayoutExample :: Control
flowLayoutExample =
  portableGroup
    6010
    "Flow: fixed basis + 1× and 2× growth"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 12}
        ( LayoutFlow
            defaultRow
              { flowGap = 8
              , flowCrossAlignment = CrossCenter
              }
            [ FlowItem defaultFlowItem {itemBasis = FixedBasis 130, itemShrink = 0} (LayoutLeaf (ElementKey 6011))
            , FlowItem defaultFlowItem {itemGrow = 1} (LayoutLeaf (ElementKey 6012))
            , FlowItem defaultFlowItem {itemGrow = 2} (LayoutLeaf (ElementKey 6013))
            ]
        )
    )
    [ layoutButton 6011 "Fixed 130"
    , layoutButton 6012 "Grow 1"
    , layoutButton 6013 "Grow 2"
    ]

alignmentLayoutExample :: Control
alignmentLayoutExample =
  portableGroup
    6020
    "Distribution and cross-axis alignment"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 10}
        ( LayoutFlow
            defaultColumn {flowGap = 8, flowCrossAlignment = CrossStretch}
            [ FlowItem defaultFlowItem {itemBasis = FixedBasis 36, itemShrink = 0}
                ( LayoutFlow
                    defaultRow {flowMainAlignment = SpaceBetween, flowCrossAlignment = CrossCenter}
                    (naturalLayoutLeaves [6021, 6022, 6023])
                )
            , FlowItem defaultFlowItem {itemBasis = FixedBasis 36, itemShrink = 0}
                ( LayoutFlow
                    defaultRow {flowMainAlignment = SpaceEvenly, flowCrossAlignment = CrossStretch}
                    (naturalLayoutLeaves [6024, 6025, 6026])
                )
            ]
        )
    )
    [ layoutButton 6021 "Start"
    , layoutButton 6022 "Between"
    , layoutButton 6023 "End"
    , layoutBadge 6024 "Even 1" "stretch"
    , layoutBadge 6025 "Even 2" "stretch"
    , layoutBadge 6026 "Even 3" "stretch"
    ]

gridLayoutExample :: GalleryModel -> Control
gridLayoutExample model =
  portableGroup
    6030
    "Grid: fixed, content, minmax/fraction, spans and per-cell alignment"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 12}
        ( LayoutGrid
            defaultGrid
              { gridColumns =
                  [ FixedTrack 170
                  , MaxContentTrack
                  , MinMaxTrack (FixedTrack 180) (FractionTrack 1)
                  ]
              , gridRows = [AutoTrack, FractionTrack 1]
              , gridColumnGap = 10
              , gridRowGap = 10
              , gridInlineAlignment = BoxStretch
              , gridBlockAlignment = BoxCenter
              }
            [ GridItem 0 0 1 1 Nothing Nothing (LayoutLeaf (ElementKey 6031))
            , GridItem 1 0 1 1 (Just BoxCenter) Nothing (LayoutLeaf (ElementKey 6032))
            , GridItem 2 0 1 1 Nothing Nothing (LayoutLeaf (ElementKey 6033))
            , GridItem 0 1 2 1 Nothing Nothing (LayoutLeaf (ElementKey 6034))
            , GridItem 2 1 1 1 Nothing (Just BoxStretch) (LayoutLeaf (ElementKey 6035))
            ]
        )
    )
    [ layoutBadge 6031 "Fixed track" "170 dp"
    , layoutButton 6032 "Max-content"
    , layoutBadge 6033 "minmax(180, 1fr)" "takes remaining width"
    , ProgressBar (progressSpec 6034 (Rect 0 0 320 20) model.galleryNumber 0 10)
    , CheckBox (toggleSpec 6035 (Rect 0 0 180 32) "Spanning neighbor" model.galleryToggle)
    ]

overlayLayoutExample :: Control
overlayLayoutExample =
  portableGroup
    6040
    "Overlay: logical parent anchors"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 10}
        ( LayoutOverlay
            defaultOverlay {overlayClip = True}
            [ OverlayItem (Anchor AnchorStretch AnchorStretch) noInsets 0 0 (LayoutLeaf (ElementKey 6041))
            , OverlayItem (Anchor AnchorStart AnchorStart) (uniformInsets 8) 0 0 (LayoutLeaf (ElementKey 6042))
            , OverlayItem (Anchor AnchorEnd AnchorStart) (uniformInsets 8) 0 0 (LayoutLeaf (ElementKey 6043))
            , OverlayItem (Anchor AnchorCenter AnchorCenter) noInsets 0 0 (LayoutLeaf (ElementKey 6044))
            , OverlayItem (Anchor AnchorEnd AnchorEnd) (uniformInsets 8) 0 0 (LayoutLeaf (ElementKey 6045))
            ]
        )
    )
    [ layoutBadge 6041 "Stretch base" "Every overlay child may be any native control"
    , layoutButton 6042 "Top start"
    , layoutButton 6043 "Top end"
    , layoutBadge 6044 "Centered" "natural size"
    , layoutButton 6045 "Bottom end"
    ]

wrapLayoutExample :: Control
wrapLayoutExample =
  portableGroup
    6050
    "Wrap: intrinsic items form deterministic lines"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 12}
        ( LayoutWrap
            defaultWrap
              { wrapFlow = defaultRow {flowGap = 8, flowCrossAlignment = CrossCenter}
              , wrapLineGap = 8
              }
            (naturalLayoutLeaves [6051 .. 6058])
        )
    )
    [layoutButton key ("Item " <> Text.pack (show (key - 6050))) | key <- [6051 .. 6058]]

splitLayoutExample :: Control
splitLayoutExample =
  portableGroup
    6060
    "Split allocation: minimum, preferred, maximum and stretch weight"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 12}
        ( LayoutSplit
            defaultSplit {splitDivider = 8}
            [ SplitItem 120 180 (Just 260) 0 (LayoutLeaf (ElementKey 6061))
            , SplitItem 220 320 Nothing 1 (LayoutLeaf (ElementKey 6062))
            , SplitItem 140 220 (Just 360) 0.6 (LayoutLeaf (ElementKey 6063))
            ]
        )
    )
    [ layoutBadge 6061 "Sidebar" "min 120 / preferred 180"
    , layoutBadge 6062 "Editor" "stretch 1"
    , layoutBadge 6063 "Inspector" "max 360 / stretch 0.6"
    ]

linedTableLayoutExample :: Control
linedTableLayoutExample =
  portableGroup
    6100
    "Grid table: explicit header, rows, columns and separator tracks"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 12}
        ( LayoutGrid
            defaultGrid
              { gridColumns =
                  [ FixedTrack 1
                  , FractionTrack 1.5
                  , FixedTrack 1
                  , FractionTrack 1
                  , FixedTrack 1
                  , FractionTrack 1
                  , FixedTrack 1
                  , FractionTrack 0.7
                  , FixedTrack 1
                  ]
              , gridRows =
                  [ FixedTrack 1
                  , FixedTrack 34
                  , FixedTrack 1
                  , FixedTrack 32
                  , FixedTrack 1
                  , FixedTrack 32
                  , FixedTrack 1
                  , FixedTrack 32
                  , FixedTrack 1
                  , FixedTrack 32
                  , FixedTrack 1
                  ]
              , gridColumnGap = 0
              , gridRowGap = 0
              , gridInlineAlignment = BoxStretch
              , gridBlockAlignment = BoxStretch
              }
            (cellItems <> verticalLines <> horizontalLines)
        )
    )
    (cellControls <> verticalLineControls <> horizontalLineControls)
  where
    tableCells =
      [ (6110, 1, 1, "NAME")
      , (6111, 3, 1, "TYPE")
      , (6112, 5, 1, "STATUS")
      , (6113, 7, 1, "SIZE")
      , (6114, 1, 3, "Main.hs")
      , (6115, 3, 3, "Haskell")
      , (6116, 5, 3, "Modified")
      , (6117, 7, 3, "12 KB")
      , (6118, 1, 5, "HaskeLUI.Core")
      , (6119, 3, 5, "Module")
      , (6120, 5, 5, "Clean")
      , (6121, 7, 5, "8 KB")
      , (6122, 1, 7, "README.md")
      , (6123, 3, 7, "Markdown")
      , (6124, 5, 7, "Clean")
      , (6125, 7, 7, "4 KB")
      , (6126, 1, 9, "package.yaml")
      , (6127, 3, 9, "YAML")
      , (6128, 5, 9, "Clean")
      , (6129, 7, 9, "3 KB")
      ]
    verticalSeparators = zip [6140 .. 6144] [0, 2, 4, 6, 8]
    horizontalSeparators = zip [6150 .. 6155] [0, 2, 4, 6, 8, 10]
    cellItems =
      [ GridItem column row 1 1 Nothing Nothing
          ( LayoutBox
              defaultBoxSpec
                { boxPadding = Insets 4 8 4 8
                , boxInlineAlignment = BoxStart
                , boxBlockAlignment = BoxCenter
                }
              (LayoutLeaf (ElementKey key))
          )
      | (key, column, row, _) <- tableCells
      ]
    verticalLines =
      [ GridItem column 0 1 11 Nothing Nothing (LayoutLeaf (ElementKey key))
      | (key, column) <- verticalSeparators
      ]
    horizontalLines =
      [ GridItem 0 row 9 1 Nothing Nothing (LayoutLeaf (ElementKey key))
      | (key, row) <- horizontalSeparators
      ]
    cellControls =
      [ Label (ElementKey key) (Rect 0 0 120 22) value
      | (key, _, _, value) <- tableCells
      ]
    verticalLineControls =
      [ Separator (ElementKey key) (Rect 0 0 1 168)
      | (key, _) <- verticalSeparators
      ]
    horizontalLineControls =
      [ Separator (ElementKey key) (Rect 0 0 1000 1)
      | (key, _) <- horizontalSeparators
      ]

adaptiveLayoutExample :: Control
adaptiveLayoutExample =
  portableGroup
    6070
    "Adaptive layout: identical retained controls, compact and wide strategies"
    ( LayoutBox
        defaultBoxSpec {boxPadding = uniformInsets 12}
        ( LayoutFlow
            defaultRow {flowGap = 16, flowCrossAlignment = CrossStretch}
            [ FlowItem defaultFlowItem {itemBasis = FixedBasis 320, itemShrink = 0} (LayoutLeaf (ElementKey 6071))
            , FlowItem defaultFlowItem {itemGrow = 1} (LayoutLeaf (ElementKey 6072))
            ]
        )
    )
    [ adaptiveDemo 6071 6080
    , adaptiveDemo 6072 6090
    ]

adaptiveDemo :: Word -> Word -> Control
adaptiveDemo rootKey firstKey =
  let keys = [firstKey, firstKey + 1, firstKey + 2]
      rowLayout =
        LayoutFlow
          defaultRow {flowGap = 6, flowCrossAlignment = CrossStretch}
          [FlowItem defaultFlowItem {itemGrow = 1} (LayoutLeaf (ElementKey (fromIntegral key))) | key <- keys]
      columnLayout =
        LayoutFlow
          defaultColumn {flowGap = 6, flowCrossAlignment = CrossStretch}
          [FlowItem defaultFlowItem {itemGrow = 1} (LayoutLeaf (ElementKey (fromIntegral key))) | key <- keys]
   in LayoutContainer
        LayoutContainerSpec
          { layoutContainerKey = ElementKey (fromIntegral rootKey)
          , layoutContainerFrame = Rect 0 0 400 150
          , layoutContainerPresentation = PlainLayoutContainer
          , layoutContainerEnvironment = defaultLayoutEnvironment
          , layoutContainerLayout =
              LayoutAdaptive
                [ AdaptiveCase Nothing (Just 399) columnLayout
                , AdaptiveCase (Just 400) Nothing rowLayout
                ]
                rowLayout
          , layoutContainerChildren =
              [layoutButton key (if offset == 0 then "Adaptive" else "Pane " <> Text.pack (show offset)) | (key, offset) <- zip keys [0 :: Int ..]]
          }

portableGroup :: Word -> Text -> Layout ElementKey -> [Control] -> Control
portableGroup key title layout children =
  LayoutContainer
    LayoutContainerSpec
      { layoutContainerKey = ElementKey (fromIntegral key)
      , layoutContainerFrame = Rect 0 0 600 150
      , layoutContainerPresentation = GroupLayoutContainer title
      , layoutContainerEnvironment = defaultLayoutEnvironment
      , layoutContainerLayout = layout
      , layoutContainerChildren = children
      }

naturalLayoutLeaves :: [Word] -> [FlowItem ElementKey]
naturalLayoutLeaves = fmap (FlowItem defaultFlowItem . LayoutLeaf . ElementKey . fromIntegral)

layoutButton :: Word -> Text -> Control
layoutButton key title =
  Button (ElementKey (fromIntegral key)) (Rect 0 0 104 32) title generalCommand True

layoutBadge :: Word -> Text -> Text -> Control
layoutBadge key title detail =
  Badge
    MessageControlSpec
      { messageControlKey = ElementKey (fromIntegral key)
      , messageControlFrame = Rect 0 0 150 46
      , messageControlTitle = title
      , messageControlMessage = detail
      }

galleryCommands :: [CommandSpec]
galleryCommands =
  [ CommandSpec generalCommand "Run Action" (Just "g") True
  , CommandSpec closeCommand "Close Gallery" (Just "w") True
  , CommandSpec dialogCommand "Show Dialog" Nothing True
  , CommandSpec alertCommand "Show Alert" Nothing True
  , CommandSpec popoverCommand "Show Popover" Nothing True
  , CommandSpec secondaryCommand "Refresh" Nothing True
  , CommandSpec destructiveCommand "Inspect" Nothing True
  ]

galleryMenu :: [MenuEntry]
galleryMenu =
  [ MenuCommand "Run Action" generalCommand True
  , MenuCommand "Refresh" secondaryCommand True
  , MenuSeparator
  , MenuCommand "Inspect" destructiveCommand True
  ]

galleryChoices :: [ChoiceItem]
galleryChoices =
  [ ChoiceItem (ChoiceKey 1) (ControlLabel "First" (Just (SystemSymbol "1.circle"))) True
  , ChoiceItem (ChoiceKey 2) (ControlLabel "Second" (Just (SystemSymbol "2.circle"))) True
  , ChoiceItem (ChoiceKey 3) (ControlLabel "Disabled" Nothing) False
  ]

galleryCollectionItems :: GalleryModel -> [CollectionItem]
galleryCollectionItems model =
  [ CollectionItem (CollectionItemKey 1) "Project" "root" Nothing 0 True (isExpanded 1)
  , CollectionItem (CollectionItemKey 2) "Main.hs" "Haskell source" Nothing 1 False False
  , CollectionItem (CollectionItemKey 3) "HaskeLUI.Core" "library module" Nothing 1 False False
  , CollectionItem (CollectionItemKey 4) "README.md" "documentation" Nothing 0 False False
  , CollectionItem (CollectionItemKey 5) "Lazy folder" "children not loaded" Nothing 0 True False
  ]
  where
    isExpanded key = CollectionItemKey key `elem` model.galleryExpandedItems

actionSpec :: Word -> Rect -> Text -> Maybe ImageSource -> ActionControlSpec
actionSpec key frame title icon =
  ActionControlSpec (ElementKey (fromIntegral key)) frame (ControlLabel title icon) generalCommand True

toggleSpec :: Word -> Rect -> Text -> ToggleValue -> ToggleControlSpec
toggleSpec key frame title value =
  ToggleControlSpec (ElementKey (fromIntegral key)) frame (ControlLabel title Nothing) value True

choiceSpec :: Word -> Rect -> Maybe ChoiceKey -> ChoiceControlSpec
choiceSpec key frame selected =
  ChoiceControlSpec (ElementKey (fromIntegral key)) frame galleryChoices selected True

splitSpec :: Word -> Rect -> Text -> Maybe Bool -> SplitButtonSpec
splitSpec key frame title toggle =
  SplitButtonSpec
    (ElementKey (fromIntegral key)) frame (ControlLabel title (Just (SystemSymbol "square.grid.2x2")))
    generalCommand galleryMenu toggle True

textInputSpec :: Word -> Rect -> GalleryModel -> Text -> TextInputSpec
textInputSpec key frame model placeholder =
  TextInputSpec (ElementKey (fromIntegral key)) frame model.galleryText placeholder [] True False

suggestInputSpec :: Word -> Rect -> GalleryModel -> Text -> TextInputSpec
suggestInputSpec key frame model placeholder =
  (textInputSpec key frame model placeholder) {textInputSuggestions = galleryChoices}

numericSpec :: Word -> Rect -> Double -> Double -> Double -> Double -> NumericControlSpec
numericSpec key frame value minimumValue maximumValue step =
  NumericControlSpec (ElementKey (fromIntegral key)) frame value minimumValue maximumValue step True

dateSpec :: Word -> Rect -> GalleryModel -> DateControlSpec
dateSpec key frame model = DateControlSpec (ElementKey (fromIntegral key)) frame model.galleryDate True

timeSpec :: Word -> Rect -> GalleryModel -> TimeControlSpec
timeSpec key frame model = TimeControlSpec (ElementKey (fromIntegral key)) frame model.galleryTime True

progressSpec :: Word -> Rect -> Double -> Double -> Double -> ProgressControlSpec
progressSpec key frame value minimumValue maximumValue =
  ProgressControlSpec (ElementKey (fromIntegral key)) frame value minimumValue maximumValue

collectionSpec :: Word -> Rect -> GalleryModel -> CollectionSelectionMode -> CollectionControlSpec
collectionSpec key frame model mode =
  CollectionControlSpec
    (ElementKey (fromIntegral key))
    frame
    (galleryCollectionItems model)
    mode
    selection
    PlatformDefaultRows
    True
  where
    selection = case mode of
      NoCollectionSelection -> []
      SingleCollectionSelection -> take 1 model.gallerySelection
      MultipleCollectionSelection -> model.gallerySelection

imageSpec :: Word -> Rect -> ImageSource -> Text -> ImageControlSpec
imageSpec key frame source description =
  ImageControlSpec (ElementKey (fromIntegral key)) frame source description

editorSpec :: Word -> Rect -> GalleryModel -> Bool -> TextEditorSpec
editorSpec key frame model focused =
  TextEditorSpec
    { textEditorKey = ElementKey (fromIntegral key)
    , textEditorFrame = frame
    , textEditorText = model.galleryText
    , textEditorRevision = model.galleryRevision
    , textEditorBaseStyle = mempty {textFontFamily = Just MonospaceFont, textFontSize = Just 13}
    , textEditorLayers =
        [ TextLayer
            (TextLayerKey (fromIntegral key))
            model.galleryRevision
            [TextSpan (TextRange 0 (min 4 (Text.length model.galleryText)))
              (mempty {textForeground = Just (RGBA 0.72 0.2 0.16 1), textFontWeight = Just Bold})
            | not (Text.null model.galleryText)
            ]
        ]
    , textEditorNavigation = Nothing
    , textEditorFocused = focused
    }

handleGalleryEvent :: UIEvent -> GalleryModel -> Transaction GalleryModel
handleGalleryEvent event model =
  transaction "Control gallery event" NoUndo (const updated)
  where
    logged next = next {galleryLastEvent = Text.pack (show event)}
    updated = logged $ case event of
      CommandInvoked command
        | command == closeCommand -> model {galleryWindowOpen = False}
        | command == dialogCommand -> model {galleryDialogVisible = True, galleryPage = Just shellPage}
        | command == alertCommand -> model {galleryAlertVisible = True, galleryPage = Just shellPage}
        | command == popoverCommand -> model {galleryPopoverVisible = True, galleryPage = Just shellPage}
        | otherwise -> model
      TextChanged _ value ->
        model
          { galleryText = value
          , galleryRevision = TextRevision (model.galleryRevision.unTextRevision + 1)
          }
      ToggleChanged _ value -> model {galleryToggle = value}
      ChoiceChanged key selected
        | key == rootTabKey -> model {galleryPage = selected}
        | otherwise -> model {galleryChoice = selected}
      NumberChanged _ value -> model {galleryNumber = value}
      DateChanged _ value -> model {galleryDate = value}
      TimeChanged _ value -> model {galleryTime = value}
      ColorChanged _ value -> model {galleryColor = value}
      CollectionSelectionChanged _ value -> model {gallerySelection = value}
      CollectionExpansionChanged _ item expanded ->
        model
          { galleryExpandedItems =
              if expanded
                then item : filter (/= item) model.galleryExpandedItems
                else filter (/= item) model.galleryExpandedItems
          }
      DisclosureChanged _ expanded -> model {galleryDisclosureExpanded = expanded}
      PresentationClosed key _
        | key == ElementKey 412 -> model {galleryDialogVisible = False}
        | key == ElementKey 413 -> model {galleryAlertVisible = False}
        | key == ElementKey 414 -> model {galleryPopoverVisible = False}
        | otherwise -> model
      WindowCloseRequested key
        | key == galleryWindowKey -> model {galleryWindowOpen = False}
      _ -> model
