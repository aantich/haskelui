{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Total, named model properties and their pure action vocabulary.
--
-- The representation is compatible with ordinary van Laarhoven lenses, while
-- the wrapper adds stable identity for diagnostics, binding, and change/undo
-- metadata. Most applications can define @properties = rootPath@ and use
-- checked dotted paths such as @properties.document.title@.
module UIH.Property
  ( Lens'
  , Property
  , PropertyId (..)
  , PropertyTarget
  , Path
  , OptionalProperty
  , PropertyApplyError (..)
  , actionDescription
  , actionPropertyIds
  , applyAction
  , asProperty
  , batchActions
  , fromLens
  , get
  , getOptional
  , modify
  , modifyOptional
  , optionalProperty
  , optionalPropertyId
  , property
  , propertyId
  , rootPath
  , setOptional
  , (>.)
  , (.=)
  ) where

import Data.Functor.Const (Const (..))
import Data.Functor.Identity (Identity (..))
import Data.Generics.Labels ()
import qualified Data.Generics.Product.Fields as Generic
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified GHC.Records as Records
import GHC.TypeLits (KnownSymbol, symbolVal)
import UIH.Core
  ( Action
  , PropertyId (..)
  , actionDescription
  , actionPropertyIds
  , actionWithProperties
  , applyAction
  , batchActions
  )

-- | The minimal lens representation used by UIH. Lenses from @lens@,
-- @generic-lens@, or handwritten code are structurally compatible.
type Lens' source focus =
  forall functor.
  Functor functor =>
  (focus -> functor focus) ->
  source ->
  functor source

data Property model value = Property
  !PropertyId
  (Lens' model value)

-- | Wrap a total lens with stable UIH identity.
property :: PropertyId -> Lens' model value -> Property model value
property = Property

-- | Explicit lens-interoperability spelling of 'property'.
fromLens :: PropertyId -> Lens' model value -> Property model value
fromLens = property

propertyId
  :: PropertyTarget target model value
  => target
  -> PropertyId
propertyId target = identifier
  where
    Property identifier _ = asProperty target

-- | Values accepted by property-reading, action, and binding constructors.
class PropertyTarget target model value | target -> model value where
  asProperty :: target -> Property model value

instance PropertyTarget (Property model value) model value where
  asProperty = id

-- | A checked dotted path that accumulates both a generic lens and its
-- qualified property identity.
data Path root focus = Path
  !PropertyId
  (Lens' root focus)

rootPath :: Path model model
rootPath = Path (PropertyId "") id

instance PropertyTarget (Path model value) model value where
  asProperty (Path identifier focus) = Property identifier focus

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

get :: PropertyTarget target model value => target -> model -> value
get target = viewLens focus
  where
    Property _ focus = asProperty target

infixr 8 >.

-- | Compose total properties and qualify their identities.
(>.)
  :: Property outer inner
  -> Property inner value
  -> Property outer value
(Property outerId outer) >. (Property innerId inner) =
  Property (qualify outerId innerId) (outer . inner)

infixr 1 .=

-- | Construct an inspectable action that assigns one authoritative property.
(.=)
  :: PropertyTarget target model value
  => target
  -> value
  -> Action model
target .= value =
  actionWithProperties
    ("Set " <> unPropertyId identifier)
    [identifier]
    (setLens focus value)
  where
    Property identifier focus = asProperty target

-- | Construct an inspectable action that modifies one authoritative property.
modify
  :: PropertyTarget target model value
  => target
  -> (value -> value)
  -> Action model
modify target change =
  actionWithProperties
    ("Modify " <> unPropertyId identifier)
    [identifier]
    (overLens focus change)
  where
    Property identifier focus = asProperty target

-- | Partial focus remains a separate type: absence is explicit and cannot be
-- confused with the total guarantee of 'Property'.
data OptionalProperty model value = OptionalProperty
  !PropertyId
  (model -> Maybe value)
  (value -> model -> Either PropertyApplyError model)

data PropertyApplyError
  = MissingPropertyTarget !PropertyId
  | RejectedPropertyUpdate !PropertyId !Text
  deriving stock (Eq, Show)

optionalProperty
  :: PropertyId
  -> (model -> Maybe value)
  -> (value -> model -> Either PropertyApplyError model)
  -> OptionalProperty model value
optionalProperty = OptionalProperty

optionalPropertyId :: OptionalProperty model value -> PropertyId
optionalPropertyId (OptionalProperty identifier _ _) = identifier

getOptional :: OptionalProperty model value -> model -> Maybe value
getOptional (OptionalProperty _ getter _) = getter

setOptional
  :: OptionalProperty model value
  -> value
  -> model
  -> Either PropertyApplyError model
setOptional (OptionalProperty _ _ setter) = setter

modifyOptional
  :: OptionalProperty model value
  -> (value -> value)
  -> model
  -> Either PropertyApplyError model
modifyOptional optional change model =
  case getOptional optional model of
    Nothing -> Left (MissingPropertyTarget (optionalPropertyId optional))
    Just current -> setOptional optional (change current) model

qualify :: PropertyId -> PropertyId -> PropertyId
qualify (PropertyId outer) (PropertyId inner)
  | Text.null outer = PropertyId inner
  | Text.null inner = PropertyId outer
  | otherwise = PropertyId (outer <> "." <> inner)

viewLens :: Lens' source focus -> source -> focus
viewLens focus source = getConst (focus Const source)

setLens :: Lens' source focus -> focus -> source -> source
setLens focus value source =
  runIdentity (focus (const (Identity value)) source)

overLens :: Lens' source focus -> (focus -> focus) -> source -> source
overLens focus change source =
  runIdentity (focus (Identity . change) source)
