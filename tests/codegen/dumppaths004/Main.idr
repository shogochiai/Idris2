module Main

import System.Coverage

-- Two functions, each with two paths (a nil/cons and a nothing/just split).
-- Under --dumppaths-hits every canonical case-tree leaf records its path-id;
-- enterTest sets the opaque label those hits are attributed to.

listHead : List Int -> Int
listHead []        = 0
listHead (x :: _)  = x

fromOpt : Maybe Int -> Int
fromOpt Nothing  = 0
fromOpt (Just x) = x

-- Two "tests", each labels itself then exercises ONE function's cons/just path.
-- So the hits file must attribute listHead's path to "T_LIST" and fromOpt's to
-- "T_OPT" — never crossed.
runListTest : IO ()
runListTest = do
  enterTest "T_LIST"
  printLn (listHead [7, 8])

runOptTest : IO ()
runOptTest = do
  enterTest "T_OPT"
  printLn (fromOpt (Just 9))

main : IO ()
main = do
  runListTest
  runOptTest
