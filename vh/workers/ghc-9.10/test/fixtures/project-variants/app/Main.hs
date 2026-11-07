module Main where
import Variants (answer)
import Details (detail)
main :: IO ()
main = putStrLn (detail ++ show answer)
