module Main

classify : Int -> String
classify 0 = "zero"
classify _ = "other"

main : IO ()
main = do
  putStrLn (classify 0)
  putStrLn (classify 5)
