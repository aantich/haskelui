{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import UIH.Core

main :: IO ()
main = do
  let increment = transaction "Increment" (SingleUndo (UndoGroup "counter")) (+ 1)
  if applyTransaction increment (1 :: Int) == 2
    then putStrLn "uih-core: transaction smoke test passed"
    else error "uih-core: transaction application failed"
