module Main

partial
partialMaybe : Maybe Int -> Int
partialMaybe (Just x) = x

safeHead : List a -> Maybe a
safeHead [] = Nothing
safeHead (x :: xs) = Just x

main : IO ()
main = pure ()
