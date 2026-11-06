{-# LANGUAGE CPP #-}
module Component (componentValue) where

#if defined(EXECUTABLE_CONTEXT)
componentValue :: Int
componentValue = 1
#elif defined(TEST_CONTEXT)
componentValue :: Bool
componentValue = True
#else
#error Component must be loaded with its actual component CPP settings
#endif
