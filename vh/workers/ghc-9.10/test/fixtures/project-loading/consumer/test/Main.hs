module Main where

import Component (componentValue)

proof :: Bool
proof = componentValue

main :: IO ()
main = print proof
