module C (unopened, Box (..)) where

unopened :: Int -> String
unopened = show

data Box a = Box { unBox :: a }

privateFunction :: Int -> Int
privateFunction = negate
