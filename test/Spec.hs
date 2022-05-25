module Main (main) where

import Test.Tasty qualified as Tasty
import Prelude

import OffChain.Test (offChainTests)
import Tx.Spec qualified as Tx (tests)

main :: IO ()
main = Tasty.defaultMain tests

tests :: Tasty.TestTree
tests =
  Tasty.testGroup
    "Hydra-demo"
    [ offChainTests
    , Tx.tests
    ]
