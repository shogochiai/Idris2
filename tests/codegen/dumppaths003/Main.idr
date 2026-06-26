module Main

-- Record fields generate a plain selector `Point.x` (a thin wrapper) AND a
-- postfix projection `Point.(.x)`. The canonical-paths dump must list ONLY the
-- projection per field, never the duplicate wrapper, so each field is a single
-- obligation and code that only ever writes `r.field` (the projection form) does
-- not leave the wrapper as a structurally-unreachable "missing" path.
record Point where
  constructor MkPoint
  x : Int
  y : Int

usePostfix : Point -> Int
usePostfix p = p.x + p.y

main : IO ()
main = printLn (usePostfix (MkPoint 3 4))
