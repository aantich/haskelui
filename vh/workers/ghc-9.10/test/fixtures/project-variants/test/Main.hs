module Main where
import Details (detail)
main :: IO ()
main = print (not (null detail))
