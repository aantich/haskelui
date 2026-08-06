{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Example.ControlGallery
  ( GalleryModel (..)
  , application
  , galleryCatalogKinds
  , galleryControls
  , galleryWindowKey
  , initialModel
  , renderGallery
  , rootTabKey
  ) where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import UIH.Core

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

contentPage, inputPage, collectionPage, shellPage, containerPage :: ChoiceKey
contentPage = ChoiceKey 9201
inputPage = ChoiceKey 9202
collectionPage = ChoiceKey 9203
shellPage = ChoiceKey 9204
containerPage = ChoiceKey 9205

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
    , appView = renderGallery
    , appHandleEvent = handleGalleryEvent
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
    , windowTitle = "UIH Core Control Gallery"
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
  [ Breadcrumb
      BreadcrumbSpec
        { breadcrumbKey = ElementKey 300
        , breadcrumbFrame = Rect 18 740 1210 36
        , breadcrumbItems = galleryChoices
        , breadcrumbSelected = model.galleryChoice
        }
  , ListView (collectionSpec 301 (Rect 18 430 280 280) model SingleCollectionSelection)
  , CollectionView (collectionSpec 302 (Rect 316 430 280 280) model MultipleCollectionSelection)
  , TreeView (collectionSpec 303 (Rect 614 430 280 280) model SingleCollectionSelection)
  , TableView (collectionSpec 304 (Rect 912 430 316 280) model MultipleCollectionSelection)
  , ItemRepeater (collectionSpec 305 (Rect 18 100 390 290) model NoCollectionSelection)
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
  [ CollectionItem (CollectionItemKey 1) "Project" "root" 0 (isExpanded 1)
  , CollectionItem (CollectionItemKey 2) "Main.hs" "Haskell source" 1 False
  , CollectionItem (CollectionItemKey 3) "UIH.Core" "library module" 1 False
  , CollectionItem (CollectionItemKey 4) "README.md" "documentation" 0 False
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
    (ElementKey (fromIntegral key)) frame (galleryCollectionItems model) mode selection True
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
