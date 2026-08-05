{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

module UIH.Property.Spike
  ( Action
  , ApplyError (..)
  , Document (..)
  , ElementProperty
  , Model (..)
  , OptionalProperty
  , Path
  , Property
  , PropertyId (..)
  , applyAction
  , asProperty
  , assignOptional
  , batch
  , describeAction
  , directDocumentTitle
  , documentProperty
  , documentTitle
  , elementProperty
  , emitNamed
  , get
  , getOptional
  , invokeNamed
  , modify
  , opaqueNamed
  , optionalProperty
  , property
  , propertyId
  , properties
  , rootPath
  , selectedDocumentTitle
  , setElement
  , startNamed
  , (>.)
  , (.=)
  ) where

import Data.Generics.Labels ()
import qualified Data.Generics.Product.Fields as Generic
import Data.Functor.Const (Const (..))
import Data.Functor.Identity (Identity (..))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import qualified GHC.Records as Records
import GHC.TypeLits (KnownSymbol, symbolVal)

-- | The small van Laarhoven core required by UIH. It is structurally
-- compatible with lenses produced by generic-lens and the lens ecosystem,
-- without requiring the full lens package in uih-core.
type Lens' source focus =
  forall functor.
  Functor functor =>
  (focus -> functor focus) ->
  source ->
  functor source

view :: Lens' source focus -> source -> focus
view focus source = getConst (focus Const source)

set :: Lens' source focus -> focus -> source -> source
set focus value source = runIdentity (focus (const (Identity value)) source)

over :: Lens' source focus -> (focus -> focus) -> source -> source
over focus change source = runIdentity (focus (Identity . change) source)

newtype PropertyId = PropertyId {unPropertyId :: Text}
  deriving stock (Eq, Show)

-- | A total model property: the lens guarantees exactly one focus.
data Property model value = Property
  !PropertyId
  (Lens' model value)

property :: PropertyId -> Lens' model value -> Property model value
property = Property

propertyId :: Property model value -> PropertyId
propertyId (Property identifier _) = identifier

get :: Property model value -> model -> value
get (Property _ focus) = view focus

infixr 8 >.

(>.)
  :: Property outer inner
  -> Property inner value
  -> Property outer value
(Property outerId outer) >. (Property innerId inner) =
  Property (qualify outerId innerId) (outer . inner)

qualify :: PropertyId -> PropertyId -> PropertyId
qualify (PropertyId outer) (PropertyId inner)
  | Text.null outer = PropertyId inner
  | Text.null inner = PropertyId outer
  | otherwise = PropertyId (outer <> "." <> inner)

-- | UIH's reified action language can retain property identity while using
-- the lens to interpret an update.
data Action model where
  SetModel :: Property model value -> value -> Action model
  ModifyModel :: Property model value -> (value -> value) -> Action model
  SetElement :: ElementProperty value -> value -> Action model
  InvokeNamed :: Text -> Action model
  StartNamed :: Text -> Action model
  EmitNamed :: Text -> Action model
  BatchActions :: [Action model] -> Action model
  OpaqueNamed :: Text -> Action model

class Assign target model value | target -> model value where
  (.=) :: target -> value -> Action model

infixr 1 .=

instance Assign (Property model value) model value where
  (.=) = SetModel

modify
  :: Property model value
  -> (value -> value)
  -> Action model
modify = ModifyModel

applyAction :: Action model -> model -> model
applyAction (SetModel (Property _ focus) value) = set focus value
applyAction (ModifyModel (Property _ focus) change) = over focus change
applyAction (SetElement _ _) = id
applyAction (InvokeNamed _) = id
applyAction (StartNamed _) = id
applyAction (EmitNamed _) = id
applyAction (BatchActions actions) = \model ->
  foldl' (flip applyAction) model actions
applyAction (OpaqueNamed _) = id

describeAction :: Action model -> Text
describeAction (SetModel (Property (PropertyId identifier) _) _) =
  "SetModel " <> identifier
describeAction (ModifyModel (Property (PropertyId identifier) _) _) =
  "ModifyModel " <> identifier
describeAction (SetElement (ElementProperty identifier) _) =
  "SetElement " <> identifier
describeAction (InvokeNamed identifier) = "Invoke " <> identifier
describeAction (StartNamed identifier) = "Start " <> identifier
describeAction (EmitNamed identifier) = "Emit " <> identifier
describeAction (BatchActions actions) =
  "Batch [" <> Text.intercalate ", " (fmap describeAction actions) <> "]"
describeAction (OpaqueNamed identifier) = "Opaque " <> identifier

invokeNamed :: Text -> Action model
invokeNamed = InvokeNamed

startNamed :: Text -> Action model
startNamed = StartNamed

emitNamed :: Text -> Action model
emitNamed = EmitNamed

batch :: [Action model] -> Action model
batch = BatchActions

opaqueNamed :: Text -> Action model
opaqueNamed = OpaqueNamed

-- | Element-owned properties deliberately have no model parameter. The
-- action's result type supplies the application model at the use site.
newtype ElementProperty value = ElementProperty Text

elementProperty :: Text -> ElementProperty value
elementProperty = ElementProperty

setElement :: ElementProperty value -> value -> Action model
setElement = SetElement

-- | A path carries the same lens and identity as Property, but supports
-- chained OverloadedRecordDot syntax. Its constructor is positional so GHC
-- permits a polymorphic virtual HasField instance for the Path type.
data Path root focus = Path
  !PropertyId
  (Lens' root focus)

rootPath :: Path model model
rootPath = Path (PropertyId "") id

instance
  ( KnownSymbol field
  , Generic.HasField field focus focus value value
  ) =>
  Records.HasField field (Path root focus) (Path root value)
  where
  getField (Path prefix outer) =
    Path
      (qualify prefix (PropertyId fieldName))
      (outer . Generic.field @field)
    where
      fieldName = Text.pack (symbolVal (Proxy @field))

asProperty :: Path model value -> Property model value
asProperty (Path identifier focus) = Property identifier focus

instance Assign (Path model value) model value where
  path .= value = SetModel (asProperty path) value

-- | Partial focus remains a different type. This spike makes absence
-- explicit instead of silently treating a traversal as a total lens.
data OptionalProperty model value = OptionalProperty
  !PropertyId
  (model -> Maybe value)
  (value -> model -> Either ApplyError model)

data ApplyError
  = MissingTarget !PropertyId
  deriving stock (Eq, Show)

optionalProperty
  :: PropertyId
  -> (model -> Maybe value)
  -> (value -> model -> Either ApplyError model)
  -> OptionalProperty model value
optionalProperty = OptionalProperty

getOptional :: OptionalProperty model value -> model -> Maybe value
getOptional (OptionalProperty _ getter _) = getter

assignOptional
  :: OptionalProperty model value
  -> value
  -> model
  -> Either ApplyError model
assignOptional (OptionalProperty _ _ setter) = setter

data Document = Document
  { title :: !Text
  , body :: !Text
  }
  deriving stock (Eq, Generic, Show)

data Model = Model
  { document :: !Document
  , count :: !Int
  , documents :: !(Map Int Document)
  , selectedDocument :: !(Maybe Int)
  }
  deriving stock (Eq, Generic, Show)

-- | An application can give its root path this conventional name, producing
-- the exact surface syntax under discussion.
properties :: Path Model Model
properties = rootPath

documentProperty :: Property Model Document
documentProperty = property (PropertyId "document") #document

titleProperty :: Property Document Text
titleProperty = property (PropertyId "title") #title

documentTitle :: Property Model Text
documentTitle = documentProperty >. titleProperty

directDocumentTitle :: Property Model Text
directDocumentTitle =
  property (PropertyId "document.title.direct") (#document . #title)

selectedDocumentTitle :: OptionalProperty Model Text
selectedDocumentTitle =
  optionalProperty
    (PropertyId "documents.selected.title")
    getSelectedTitle
    setSelectedTitle
  where
    getSelectedTitle model = do
      key <- model.selectedDocument
      selected <- Map.lookup key model.documents
      pure selected.title

    setSelectedTitle newTitle model =
      case model.selectedDocument of
        Nothing -> Left (MissingTarget (PropertyId "documents.selected.title"))
        Just key ->
          case Map.lookup key model.documents of
            Nothing -> Left (MissingTarget (PropertyId "documents.selected.title"))
            Just selected ->
              Right
                model
                  { documents =
                      Map.insert key (selected {title = newTitle}) model.documents
                  }
