{-# LANGUAGE CPP #-}
module Upstream (value) where

#ifndef STAGE0_UPSTREAM
#error Missing upstream component settings
#endif

value :: Int
value = 41
