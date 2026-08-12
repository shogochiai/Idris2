||| Path attribution for programs built with path instrumentation.
|||
||| A program compiled with path instrumentation records which of its execution
||| paths ran. `enterTest` lets the program additionally say *under which label*
||| they ran: everything from one call until the next is attributed to that
||| label. The label is opaque — neither the compiler nor the runtime interprets
||| it — so a caller may use a test name, a requirement id, or any grouping key.
|||
||| Calling this is always safe. The hook lives in the runtime support library
||| rather than behind a compiler primitive, so it links and runs in an ordinary
||| build too, where it is a cheap no-op.
module System.Coverage

%default total

%foreign "C:idris2_enterTest, libidris2_support, idris_pathcov.h"
         "scheme:blodwen-enter-test"
         "node:lambda:(label) => { globalThis.__idris2_label = label; }"
prim__enterTest : String -> PrimIO ()

||| Attribute subsequent path hits to the given label, until the next call.
export
enterTest : HasIO io => String -> io ()
enterTest label = primIO (prim__enterTest label)
