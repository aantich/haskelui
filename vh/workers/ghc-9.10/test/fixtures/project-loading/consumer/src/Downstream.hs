{-# LANGUAGE CPP #-}
module Downstream (answer) where

#ifndef STAGE0_DOWNSTREAM
#error Missing downstream component settings
#endif

import Upstream (value)

answer :: Int
answer = value + 1
