{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- This file intentionally does not compile. It is used to inspect the error
-- produced for an invalid generated property path.
module UnknownField where

import Data.Text (Text)
import UIH.Property.Spike

invalid :: Action Model
invalid = properties.document.unknown .= ("value" :: Text)

