||| Test helper for the `--dumppaths-json` codegen tests.
|||
||| Reads a canonical-paths JSON file (produced by `idris2 --dumppaths-json`) and
||| prints one tab-separated row per path:
|||
|||   function_name <TAB> path_id <TAB> branch_labels <TAB> classification <TAB> terminal_kind
|||
||| `branch_labels` is the comma-joined `branch_label` of each step, or `-` when a
||| path has no steps. Rows are emitted in file order; the test `run` scripts
||| filter (grep), project (cut) and sort (safesort) as they need.
|||
||| This exists so the tests stay in the Idris toolchain end-to-end -- the JSON is
||| parsed by contrib's `Language.JSON`, not an external post-processor.
module PathsExtract

import Language.JSON
import Data.List
import Data.Maybe
import Data.String
import System
import System.File

field : String -> JSON -> Maybe JSON
field k (JObject kvs) = lookup k kvs
field _ _             = Nothing

str : Maybe JSON -> String
str (Just (JString s)) = s
str _                  = ""

arr : Maybe JSON -> List JSON
arr (Just (JArray xs)) = xs
arr _                  = []

labels : JSON -> String
labels path = case map (\s => str (field "branch_label" s)) (arr (field "steps" path)) of
                   [] => "-"
                   ls => joinBy "," ls

row : String -> JSON -> String
row fn path =
  joinBy "\t"
    [ fn
    , str (field "path_id" path)
    , labels path
    , str (field "classification" path)
    , str (field "terminal_kind" path)
    ]

main : IO ()
main = do
  args <- getArgs
  let (_ :: file :: _) = args
    | _ => do putStrLn "usage: extract <paths.json>"; exitFailure
  Right content <- readFile file
    | Left err => do putStrLn ("read error: " ++ show err); exitFailure
  let Just json = parse content
    | Nothing => do putStrLn "parse error"; exitFailure
  let rows = do f <- arr (field "functions" json)
                let fn = str (field "function_name" f)
                p <- arr (field "paths" f)
                pure (row fn p)
  putStr (unlines rows)
