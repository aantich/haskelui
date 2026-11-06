module Main where

import Component (componentValue)

proof :: Int
proof = componentValue

main :: IO ()
main = print proof
