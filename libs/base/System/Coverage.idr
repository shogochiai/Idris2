||| Path-coverage instrumentation hooks.
|||
||| These are only meaningful when the program was compiled with
||| `--dumppaths-hits` (path-coverage instrumentation). In a normal build the
||| compiler still lowers `enterTest` to its backend no-op, so calling it is
||| always safe and effectively free.
|||
||| `prim__recordPathHit` (injected automatically at every canonical case-tree
||| leaf under `--dumppaths-hits`) records WHICH paths ran. `enterTest` lets a
||| harness additionally record UNDER WHICH LABEL each path ran: the harness calls
||| `enterTest "<label>"` immediately before running a unit of work, and every
||| path hit until the next `enterTest` is attributed to that label in the hits
||| file (`<label>\t<path-id>` per line). The label is an OPAQUE string — the
||| compiler and runtime never interpret it — so a caller may use a test name, a
||| requirement id, or any other grouping key.
module System.Coverage

%default total

%extern prim__enterTest : String -> (1 x : %World) -> IORes ()

||| Set the current coverage attribution label. Every subsequent path hit (see
||| `--dumppaths-hits`) is recorded against this label until the next call. A
||| no-op unless the program was built with path-coverage instrumentation.
|||
||| The label is opaque: pass a test name, a requirement id, or any grouping key.
export
enterTest : HasIO io => String -> io ()
enterTest label = primIO (prim__enterTest label)
