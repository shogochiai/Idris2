module Compiler.Common


import Compiler.ANF
import Compiler.CompileExpr
import Compiler.Inline
import Compiler.LambdaLift
import Compiler.Opts.Constructor
import Compiler.Opts.CSE
import Compiler.VMCode

import Core.Binary.Prims
import Core.Case.CaseTree
import Core.Context
import Core.Directory
import Core.TTC

import Data.IOArray
import Data.SortedMap as SortedMap
import Data.String as String
import Data.Vect
import Libraries.Data.NameMap
import Libraries.Data.NatSet
import Libraries.Data.WithDefault
import Libraries.Utils.Scheme

import Idris.Syntax
import Idris.Version

import System.File
import System.Info

%default covering

||| Tag to indicate if the compiler needs to stop execution immediately
public export
data ControlFlow = Continue | Abort

||| Generic interface to some code generator
public export
record Codegen where
  constructor MkCG
  ||| Compile an Idris 2 expression, saving it to a file.
  compileExpr : Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
                (tmpDir : String) -> (outputDir : String) ->
                ClosedTerm -> (outfile : String) -> Core (Maybe String)
  ||| Execute an Idris 2 expression directly.
  executeExpr : Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
                (tmpDir : String) -> ClosedTerm -> Core ()
  ||| Incrementally compile definitions in the current module (toIR defs)
  ||| if supported
  ||| Takes a source file name, returns the name of the generated object
  ||| file, if successful, plus any other backend specific data in a list
  ||| of strings. The generated object file should be placed in the same
  ||| directory as the associated TTC.
  incCompileFile : Maybe (Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
                          (sourcefile : String) ->
                          Core (Maybe (String, List String)))
  ||| If incremental compilation is supported, get the output file extension
  incExt : Maybe String

-- Say which phase of compilation is the last one to use - it saves time if
-- you only ask for what you need.
public export
data UsePhase = Cases | Lifted | ANF | VMCode

Eq UsePhase where
  (==) Cases Cases = True
  (==) Lifted Lifted = True
  (==) ANF ANF = True
  (==) VMCode VMCode = True
  (==) _ _ = False

Ord UsePhase where
  compare x y = compare (tag x) (tag y)
    where
      tag : UsePhase -> Int
      tag Cases = 0
      tag Lifted = 1
      tag ANF = 2
      tag VMCode = 3

public export
record CompileData where
  constructor MkCompileData
  mainExpr : ClosedCExp -- main expression to execute. This also appears in
                     -- the definitions below as MN "__mainExpression" 0
                     -- For incremental compilation and for compiling exported
                     -- names only, this can be set to 'erased'.
  exported : List (Name, String) -- names to be made accessible to the foreign
                     -- and what they should be called in that language
  namedDefs : List (Name, FC, NamedDef)
  lambdaLifted : List (Name, LiftedDef)
       -- ^ lambda lifted definitions, if required. Only the top level names
       -- will be in the context, and (for the moment...) I don't expect to
       -- need to look anything up, so it's just an alist.
  anf : List (Name, ANFDef)
       -- ^ lambda lifted and converted to ANF (all arguments to functions
       -- and constructors transformed to either variables or Null if erased)
  vmcode : List (Name, VMDef)
       -- ^ A much simplified virtual machine code, suitable for passing
       -- to a more low level target such as C

||| compile
||| Given a value of type Codegen, produce a standalone function
||| that executes the `compileExpr` method of the Codegen
export
compile : {auto c : Ref Ctxt Defs} ->
          {auto s : Ref Syn SyntaxInfo} ->
          Codegen ->
          ClosedTerm -> (outfile : String) -> Core (Maybe String)
compile {c} {s} cg tm out
    = do d <- getDirs
         let tmpDir = execBuildDir d
         let outputDir = outputDirWithDefault d
         ensureDirectoryExists tmpDir
         ensureDirectoryExists outputDir
         logTime 1 "Code generation overall" $
             compileExpr cg c s tmpDir outputDir tm out

||| execute
||| As with `compile`, produce a functon that executes
||| the `executeExpr` method of the given Codegen
export
execute : {auto c : Ref Ctxt Defs} ->
          {auto s : Ref Syn SyntaxInfo} ->
          Codegen -> ClosedTerm -> Core ()
execute {c} {s} cg tm
    = do d <- getDirs
         let tmpDir = execBuildDir d
         ensureDirectoryExists tmpDir
         executeExpr cg c s tmpDir tm

export
incCompile : {auto c : Ref Ctxt Defs} ->
             {auto s : Ref Syn SyntaxInfo} ->
             Codegen -> String -> Core (Maybe (String, List String))
incCompile {c} {s} cg src
    = do let Just inc = incCompileFile cg
             | Nothing => pure Nothing
         inc c s src

-- If an entry isn't already decoded, get the minimal entry we need for
-- compilation, and record the Binary so that we can put it back when we're
-- done (so that we don't obliterate the definition)
getMinimalDef : ContextEntry -> Core (GlobalDef, Maybe (Namespace, Binary))
getMinimalDef (Decoded def) = pure (def, Nothing)
getMinimalDef (Coded ns bin)
    = do b <- newRef Bin bin
         cdef <- fromBuf
         refsRList <- fromBuf
         let refsR = map fromList refsRList
         fc <- fromBuf
         mul <- fromBuf
         name <- fromBuf
         let def
             = MkGlobalDef fc name (Erased fc Placeholder) NatSet.empty NatSet.empty NatSet.empty NatSet.empty mul
                           Scope.empty (specified Public) (MkTotality Unchecked IsCovering) False
                           [] Nothing refsR False False True
                           None cdef Nothing [] Nothing
         pure (def, Just (ns, bin))

-- ||| Recursively get all calls in a function definition
-- ||| Note: this only checks resolved names
getAllDesc : {auto c : Ref Ctxt Defs} ->
             List Name -> -- calls to check
             IOArray (Int, Maybe (Namespace, Binary)) ->
                            -- which nodes have been visited. If the entry is
                            -- present, it's visited. Keep the binary entry, if
                            -- we partially decoded it, so that we can put back
                            -- the full definition later.
                            -- (We only need to decode the case tree IR, and
                            -- it's expensive to decode the whole thing)
             Defs -> Core ()
getAllDesc [] arr defs = pure ()
getAllDesc (n@(Resolved i) :: rest) arr defs
  = do Nothing <- coreLift $ readArray arr i
           | Just _ => getAllDesc rest arr defs
       case !(lookupContextEntry n (gamma defs)) of
            Nothing => do log "compile.execute" 20 $ "Couldn't find " ++ show n
                          getAllDesc rest arr defs
            Just (_, entry) =>
              do (def, bin) <- getMinimalDef entry
                 ignore $ addDef n def
                 let refs = refersToRuntime def
                 if multiplicity def /= erased
                    then do coreLift_ $ writeArray arr i (i, bin)
                            let refs = refersToRuntime def
                            refs' <- traverse toResolvedNames (keys refs)
                            getAllDesc (refs' ++ rest) arr defs
                    else do log "compile.execute" 20
                               $ "Dropping " ++ show n ++ " because it's erased"
                            getAllDesc rest arr defs
getAllDesc (n :: rest) arr defs
  = do log "compile.execute" 20 $
         "Ignoring " ++ show n ++ " because it's not a Resolved name"
       getAllDesc rest arr defs

warnIfHole : Name -> NamedDef -> Core ()
warnIfHole n (MkNmError _)
    = coreLift $ putStrLn $ "Warning: compiling hole " ++ show n
warnIfHole n _ = pure ()

getNamedDef :  {auto c : Ref Ctxt Defs}
            -> (Name,FC,CDef)
            -> Core (Name, FC, NamedDef)
getNamedDef (n,fc,cdef) =
  let ndef = forgetDef cdef
   in warnIfHole n ndef >> pure (n,fc,ndef)

replaceEntry : {auto c : Ref Ctxt Defs} ->
               (Int, Maybe (Namespace, Binary)) -> Core ()
replaceEntry (i, Nothing) = pure ()
replaceEntry (i, Just (ns, b))
    = ignore $ addContextEntry ns (Resolved i) b

natHackNames : List Name
natHackNames =
    [ UN (Basic "prim__sub_Integer")
    , NS typesNS (UN $ Basic "prim__integerToNat")
    , NS eqOrdNS (UN $ Basic "compareInteger")
    ]

dumpIR : Show def => String -> List (Name, def) -> Core ()
dumpIR fn lns
    = do let cstrs = map dumpDef lns
         Right () <- coreLift $ writeFile fn (fastConcat cstrs)
               | Left err => throw (FileErr fn err)
         pure ()
  where
    fullShow : Name -> String
    fullShow (DN _ n) = show n
    fullShow n = show n

    dumpDef : (Name, def) -> String
    dumpDef (n, d) = fullShow n ++ " = " ++ show d ++ "\n"

fullShowName : Name -> String
fullShowName (DN _ n) = show n
fullShowName n = show n

allUpperBranchLabel : String -> Bool
allUpperBranchLabel str =
  let chars = unpack str in
  any isAsciiUpper chars && all isUpperLabelChar chars
  where
    isAsciiUpper : Char -> Bool
    isAsciiUpper c = c >= 'A' && c <= 'Z'

    isUpperLabelChar : Char -> Bool
    isUpperLabelChar c = isAsciiUpper c || (c >= '0' && c <= '9') || c == '_'

titleCaseBranchLabel : String -> String
titleCaseBranchLabel str = pack (go True (unpack str))
  where
    toLowerAscii : Char -> Char
    toLowerAscii c = if c >= 'A' && c <= 'Z'
                        then chr (ord c + ord 'a' - ord 'A')
                        else c

    go : Bool -> List Char -> List Char
    go _ [] = []
    go newWord ('_' :: cs) = go True cs
    go True (c :: cs) = c :: go False cs
    go False (c :: cs) = toLowerAscii c :: go False cs

branchLabelForName : Name -> String
branchLabelForName n =
  let short = nameRoot n in
  if allUpperBranchLabel short then titleCaseBranchLabel short else short

fcToMaybeString : FC -> Maybe String
fcToMaybeString fc =
  let rendered = show fc
  in if rendered == "EmptyFC" then Nothing else Just rendered

originFromCrashMessage : String -> String
originFromCrashMessage msg =
  if String.isInfixOf "Unhandled input" msg then "compiler_partial_completion"
  else if String.isInfixOf "Nat case not covered" msg then "optimizer_artifact"
  else if String.isInfixOf "No clauses" msg then "no_clause_body"
  else "unknown"

originFromBranchExp : NamedCExp -> String
originFromBranchExp (NmCrash _ msg) = originFromCrashMessage msg
originFromBranchExp _ = "user_clause"

impossibleStatusFor : String -> String
impossibleStatusFor "impossible_clause" = "impossible"
impossibleStatusFor "no_clause_body" = "impossible"
impossibleStatusFor "unknown" = "unknown"
impossibleStatusFor _ = "reachable"

partialStatusFor : String -> String
partialStatusFor "compiler_partial_completion" = "compiler_partial_completion"
partialStatusFor "unknown" = "unknown"
partialStatusFor _ = "complete"

artifactStatusFor : String -> String
artifactStatusFor "optimizer_artifact" = "optimizer_artifact"
artifactStatusFor "compiler_generated_helper" = "compiler_generated"
artifactStatusFor "unknown" = "unknown"
artifactStatusFor _ = "none"

jsonEscape : String -> String
jsonEscape str = pack (go (unpack str))
  where
    go : List Char -> List Char
    go [] = []
    go ('\\' :: cs) = '\\' :: '\\' :: go cs
    go ('"' :: cs) = '\\' :: '"' :: go cs
    go ('\n' :: cs) = '\\' :: 'n' :: go cs
    go ('\r' :: cs) = '\\' :: 'r' :: go cs
    go ('\t' :: cs) = '\\' :: 't' :: go cs
    go (c :: cs) = c :: go cs

jsonString : String -> String
jsonString str = "\"" ++ jsonEscape str ++ "\""

jsonField : String -> String -> String
jsonField key value = jsonString key ++ ": " ++ value

joinWithComma : List String -> String
joinWithComma [] = ""
joinWithComma [x] = x
joinWithComma (x :: xs) = x ++ ", " ++ joinWithComma xs

jsonObject : List String -> String
jsonObject fields = "{ " ++ joinWithComma fields ++ " }"

jsonArray : List String -> String
jsonArray xs = "[ " ++ joinWithComma xs ++ " ]"

nodeJson : String -> Nat -> Nat -> String -> String -> Maybe String -> String
nodeJson functionName caseIdx branchIdx branchLabel origin sourceSpan =
  jsonObject $
    [ jsonField "node_id" (jsonString (functionName ++ "#" ++ show caseIdx ++ ":" ++ show branchIdx))
    , jsonField "branch_index" (show branchIdx)
    , jsonField "branch_label" (jsonString branchLabel)
    , jsonField "origin" (jsonString origin)
    , jsonField "impossible_status" (jsonString (impossibleStatusFor origin))
    , jsonField "partial_status" (jsonString (partialStatusFor origin))
    , jsonField "backend_artifact_status" (jsonString (artifactStatusFor origin))
    ] ++ maybe [] (\span => [jsonField "source_span" (jsonString span)]) sourceSpan

mutual
  collectStructuredNodes : String -> Nat -> NamedCExp -> (List String, Nat)
  collectStructuredNodes functionName nextCase expr =
    case expr of
      NmConCase fc _ alts def =>
        let caseIdx = nextCase
            (altNodes, nextAfterAlts) = collectConAltNodes functionName caseIdx 0 (S nextCase) alts
            (defNodes, nextAfterDef) = collectDefaultNode functionName caseIdx (length alts) nextAfterAlts fc def
        in (altNodes ++ defNodes, nextAfterDef)
      NmConstCase fc _ alts def =>
        let caseIdx = nextCase
            (altNodes, nextAfterAlts) = collectConstAltNodes functionName caseIdx 0 (S nextCase) alts
            (defNodes, nextAfterDef) = collectDefaultNode functionName caseIdx (length alts) nextAfterAlts fc def
        in (altNodes ++ defNodes, nextAfterDef)
      NmLocal _ _ => ([], nextCase)
      NmRef _ _ => ([], nextCase)
      NmLam _ _ body => collectStructuredNodes functionName nextCase body
      NmLet _ _ val body =>
        let (valNodes, nextAfterVal) = collectStructuredNodes functionName nextCase val
            (bodyNodes, nextAfterBody) = collectStructuredNodes functionName nextAfterVal body
        in (valNodes ++ bodyNodes, nextAfterBody)
      NmApp _ fn args =>
        let (fnNodes, nextAfterFn) = collectStructuredNodes functionName nextCase fn
            (argNodes, nextAfterArgs) = collectStructuredNodesList functionName nextAfterFn args
        in (fnNodes ++ argNodes, nextAfterArgs)
      NmCon _ _ _ _ args =>
        collectStructuredNodesList functionName nextCase args
      NmOp _ _ args =>
        collectStructuredNodesList functionName nextCase (toList args)
      NmExtPrim _ _ args =>
        collectStructuredNodesList functionName nextCase args
      NmForce _ _ x => collectStructuredNodes functionName nextCase x
      NmDelay _ _ x => collectStructuredNodes functionName nextCase x
      NmPrimVal _ _ => ([], nextCase)
      NmErased _ => ([], nextCase)
      NmCrash _ _ => ([], nextCase)

  collectStructuredNodesList : String -> Nat -> List NamedCExp -> (List String, Nat)
  collectStructuredNodesList _ nextCase [] = ([], nextCase)
  collectStructuredNodesList functionName nextCase (x :: xs) =
    let (here, next1) = collectStructuredNodes functionName nextCase x
        (rest, next2) = collectStructuredNodesList functionName next1 xs
    in (here ++ rest, next2)

  collectConAltNodes : String -> Nat -> Nat -> Nat -> List NamedConAlt -> (List String, Nat)
  collectConAltNodes _ _ _ nextCase [] = ([], nextCase)
  collectConAltNodes functionName caseIdx branchIdx nextCase (MkNConAlt conName _ _ _ body :: rest) =
    let origin = originFromBranchExp body
        branchNode = nodeJson functionName caseIdx branchIdx (branchLabelForName conName) origin Nothing
        (nested, next1) = collectStructuredNodes functionName nextCase body
        (restNodes, next2) = collectConAltNodes functionName caseIdx (S branchIdx) next1 rest
    in (branchNode :: nested ++ restNodes, next2)

  collectConstAltNodes : String -> Nat -> Nat -> Nat -> List NamedConstAlt -> (List String, Nat)
  collectConstAltNodes _ _ _ nextCase [] = ([], nextCase)
  collectConstAltNodes functionName caseIdx branchIdx nextCase (MkNConstAlt c body :: rest) =
    let origin = originFromBranchExp body
        branchNode = nodeJson functionName caseIdx branchIdx (show c) origin Nothing
        (nested, next1) = collectStructuredNodes functionName nextCase body
        (restNodes, next2) = collectConstAltNodes functionName caseIdx (S branchIdx) next1 rest
    in (branchNode :: nested ++ restNodes, next2)

  collectDefaultNode : String -> Nat -> Nat -> Nat -> FC -> Maybe NamedCExp -> (List String, Nat)
  collectDefaultNode _ _ _ nextCase _ Nothing = ([], nextCase)
  collectDefaultNode functionName caseIdx branchIdx nextCase fc (Just body) =
    let origin = originFromBranchExp body
        branchNode = nodeJson functionName caseIdx branchIdx "default" origin (fcToMaybeString fc)
        (nested, next1) = collectStructuredNodes functionName nextCase body
    in (branchNode :: nested, next1)

namedDefToStructuredNodes : (Name, NamedDef) -> String
namedDefToStructuredNodes (n, def) =
  let functionName = fullShowName n
      nodes =
        case def of
          MkNmFun _ body => fst (collectStructuredNodes functionName 0 body)
          MkNmError body => fst (collectStructuredNodes functionName 0 body)
          _ => []
  in jsonObject
      [ jsonField "function_name" (jsonString functionName)
      , jsonField "nodes" (jsonArray nodes)
      ]

dumpIRJson : String -> List (Name, NamedDef) -> Core ()
dumpIRJson fn lns
    = do let payload =
               jsonObject
                 [ jsonField "compiler_version" (jsonString (showVersion False version))
                 , jsonField "functions" (jsonArray (map namedDefToStructuredNodes lns))
                 ]
         Right () <- coreLift $ writeFile fn payload
               | Left err => throw (FileErr fn err)
         pure ()

record PathTerminal where
  constructor MkPathTerminal
  classification : String
  terminalKind : String
  terminalOrigin : String
  terminalClauseId : Maybe Int
  terminalMessage : Maybe String

record PathResult where
  constructor MkPathResult
  terminal : PathTerminal
  steps : List String

pathTerminalFromCrashOrigin : String -> String -> PathTerminal
pathTerminalFromCrashOrigin "compiler_partial_completion" msg =
  MkPathTerminal "UserAdmittedPartialGap" "partial_gap"
                 "compiler_partial_completion" Nothing (Just msg)
pathTerminalFromCrashOrigin "optimizer_artifact" msg =
  MkPathTerminal "CompilerInsertedArtifact" "artifact"
                 "optimizer_artifact" Nothing (Just msg)
pathTerminalFromCrashOrigin "no_clause_body" msg =
  MkPathTerminal "UserAdmittedPartialGap" "partial_gap"
                 "no_clause_body" Nothing (Just msg)
pathTerminalFromCrashOrigin _ msg =
  MkPathTerminal "UnknownClassification" "unknown"
                 "unknown" Nothing (Just msg)

collectTermArgs : Term vars -> (Term vars, List (Term vars))
collectTermArgs tm = go tm []
  where
    go : Term vars -> List (Term vars) -> (Term vars, List (Term vars))
    go (App _ fn arg) args = go fn (arg :: args)
    go head args = (head, args)

crashMessageFromTerm : Term vars -> Maybe String
crashMessageFromTerm tm =
  let (head, args) = collectTermArgs tm in
  case head of
       Ref _ _ n =>
         if nameRoot n == "prim__crash"
            then case reverse args of
                      PrimVal _ (Str msg) :: _ => Just msg
                      _ => Nothing
            else Nothing
       _ => Nothing

pathTerminalForLeaf : CaseTree vars -> PathTerminal
pathTerminalForLeaf (STerm clauseId tm) =
  case crashMessageFromTerm tm of
       Just msg => pathTerminalFromCrashOrigin (originFromCrashMessage msg) msg
       Nothing =>
         MkPathTerminal "ReachableObligation" "reached_clause"
                        "user_clause" (Just clauseId) Nothing
pathTerminalForLeaf Impossible =
  MkPathTerminal "LogicallyUnreachable" "impossible"
                 "impossible_clause" Nothing Nothing
pathTerminalForLeaf (Unmatched msg) =
  pathTerminalFromCrashOrigin (originFromCrashMessage msg) msg
pathTerminalForLeaf _ =
  MkPathTerminal "UnknownClassification" "unknown"
                 "unknown" Nothing Nothing

stepJson : String -> Nat -> Nat -> String -> String -> Maybe String -> String
stepJson functionName caseIdx branchIdx branchLabel origin sourceSpan =
  jsonObject $
    [ jsonField "node_id" (jsonString (functionName ++ "#" ++ show caseIdx ++ ":" ++ show branchIdx))
    , jsonField "case_index" (show caseIdx)
    , jsonField "branch_index" (show branchIdx)
    , jsonField "branch_label" (jsonString branchLabel)
    , jsonField "origin" (jsonString origin)
    , jsonField "impossible_status" (jsonString (impossibleStatusFor origin))
    , jsonField "partial_status" (jsonString (partialStatusFor origin))
    , jsonField "backend_artifact_status" (jsonString (artifactStatusFor origin))
    ] ++ maybe [] (\span => [jsonField "source_span" (jsonString span)]) sourceSpan

branchOriginForSubtree : CaseTree vars -> String
branchOriginForSubtree Impossible = "impossible_clause"
branchOriginForSubtree (STerm _ tm) =
  maybe "user_clause" originFromCrashMessage (crashMessageFromTerm tm)
branchOriginForSubtree (Unmatched msg) = originFromCrashMessage msg
branchOriginForSubtree _ = "user_clause"

prependStep : String -> Nat -> Nat -> String -> String -> Maybe String -> PathResult -> PathResult
prependStep functionName caseIdx branchIdx branchLabel origin sourceSpan (MkPathResult terminal steps) =
  let step = stepJson functionName caseIdx branchIdx branchLabel origin sourceSpan
  in MkPathResult terminal (step :: steps)

mutual
  collectPathResults : String -> Nat -> CaseTree vars -> (List PathResult, Nat)
  collectPathResults functionName nextCase (Case _ _ scTy alts) =
    let caseIdx = nextCase
        sourceSpan = fcToMaybeString (getLoc scTy)
    in collectAltPathResults functionName caseIdx 0 (S nextCase) sourceSpan alts
  collectPathResults functionName nextCase leaf =
    ([MkPathResult (pathTerminalForLeaf leaf) []], nextCase)

  collectAltPathResults : String -> Nat -> Nat -> Nat -> Maybe String ->
                          List (CaseAlt vars) -> (List PathResult, Nat)
  collectAltPathResults _ _ _ nextCase _ [] = ([], nextCase)
  collectAltPathResults functionName caseIdx branchIdx nextCase sourceSpan
                        (ConCase conName _ _ subtree :: rest) =
    let (here, next1) = collectPathResults functionName nextCase subtree
        origin = branchOriginForSubtree subtree
        here' = map (prependStep functionName caseIdx branchIdx (branchLabelForName conName) origin sourceSpan) here
        (there, next2) = collectAltPathResults functionName caseIdx (S branchIdx) next1 sourceSpan rest
    in (here' ++ there, next2)
  collectAltPathResults functionName caseIdx branchIdx nextCase sourceSpan
                        (DelayCase _ _ subtree :: rest) =
    let (here, next1) = collectPathResults functionName nextCase subtree
        origin = branchOriginForSubtree subtree
        here' = map (prependStep functionName caseIdx branchIdx "Delay" origin sourceSpan) here
        (there, next2) = collectAltPathResults functionName caseIdx (S branchIdx) next1 sourceSpan rest
    in (here' ++ there, next2)
  collectAltPathResults functionName caseIdx branchIdx nextCase sourceSpan
                        (ConstCase c subtree :: rest) =
    let (here, next1) = collectPathResults functionName nextCase subtree
        origin = branchOriginForSubtree subtree
        here' = map (prependStep functionName caseIdx branchIdx (show c) origin sourceSpan) here
        (there, next2) = collectAltPathResults functionName caseIdx (S branchIdx) next1 sourceSpan rest
    in (here' ++ there, next2)
  collectAltPathResults functionName caseIdx branchIdx nextCase sourceSpan
                        (DefaultCase subtree :: rest) =
    let (here, next1) = collectPathResults functionName nextCase subtree
        origin = branchOriginForSubtree subtree
        here' = map (prependStep functionName caseIdx branchIdx "default" origin sourceSpan) here
        (there, next2) = collectAltPathResults functionName caseIdx (S branchIdx) next1 sourceSpan rest
    in (here' ++ there, next2)

pathResultJson : String -> Nat -> PathResult -> String
pathResultJson functionName pathIdx (MkPathResult terminal steps) =
  jsonObject $
    [ jsonField "path_id" (jsonString (functionName ++ "#p" ++ show pathIdx))
    , jsonField "classification" (jsonString (classification terminal))
    , jsonField "terminal_kind" (jsonString (terminalKind terminal))
    , jsonField "terminal_origin" (jsonString (terminalOrigin terminal))
    , jsonField "path_length" (show (length steps))
    , jsonField "steps" (jsonArray steps)
    ] ++ maybe [] (\clauseId => [jsonField "terminal_clause_id" (show clauseId)]) (terminalClauseId terminal)
      ++ maybe [] (\msg => [jsonField "terminal_message" (jsonString msg)]) (terminalMessage terminal)

pathResultsJson : String -> Nat -> List PathResult -> List String
pathResultsJson _ _ [] = []
pathResultsJson functionName pathIdx (path :: rest) =
  pathResultJson functionName pathIdx path :: pathResultsJson functionName (S pathIdx) rest

-- ===========================================================================
-- EffectBoundary fact-grounding (the trick-proof denominator-exclusion basis)
-- ===========================================================================
-- A path's function transitively reaches an FFI hole (popen2 / http_request /
-- ic0.call_new / openFile) iff this call-graph fixpoint says so. That reachability
-- is a COMPILER FACT (definition = ForeignDef with a matching cc, plus refersTo
-- edges) — not a human "it's IO" declaration and not a value weight. A consumer
-- can then exclude only paths whose function reaches an unexecutable boundary,
-- with the reachVia chain as the emitted witness. See
-- Coverage.Standardization.Types.EffectBoundary on the consumer side.

-- The C-spec substrings that identify each external boundary (matched in a
-- ForeignDef's calling-convention strings, e.g. "C:popen2,libidris2_support").
boundaryPrimSubstrings : List (String, String)
boundaryPrimSubstrings =
  [ ("popen2",       "ProcessSpawn")
  , ("system",       "ProcessSpawn")
  -- C:exit terminates the process — a harness-fatal, non-returning effect hole (a
  -- test that actually reached it would kill the runner). Recognised process-control
  -- boundary, not an unknown prim.
  , ("exit",         "ProcessSpawn")
  , ("http_request", "NetworkOutcall")
  -- File-handle effects: opening, closing, and EOF-probing a real handle all touch
  -- the filesystem the pure harness cannot. Recognised FileSystemIO boundary.
  , ("idris2_openFile",  "FileSystemIO")
  , ("idris2_closeFile", "FileSystemIO")
  , ("idris2_eof",       "FileSystemIO")
  -- A blocking stdin read (interactive daemon / MCP serve loops) cannot be driven by
  -- the pure test harness — it would block forever waiting for input. Recognised
  -- interactive-input boundary (FileSystemIO class), not a benign console op.
  , ("idris2_stdin",     "FileSystemIO")
  -- IC0 canister-host FFI: any %foreign linked against the IC0 system library
  -- (`,libic0`) or the canister's stable-memory runtime (`,global_registry_runtime`)
  -- is the canister's interface to the Internet Computer host — candid arg/result
  -- buffers, keccak/sha256 host hashing, EVM-RPC HTTPS outcalls, t-ECDSA signing,
  -- stable-memory read/grow, inter-canister calls. None of these symbols even exist
  -- outside the deployed WASM (a native pure test cannot link `libic0`), so reaching
  -- one is a recognised production-environment boundary the pure harness cannot drive
  -- — exactly the popen2/http_request class, not an unrecognised hole. Keyed on the
  -- linker-library cc suffix (a COMPILER FACT carried in the %foreign string), so a
  -- new IC0 binding is captured automatically without per-symbol enumeration. Tagged
  -- CanisterCall — the recognised, excludable canister-host boundary the coverage
  -- standardization lib already knows (Coverage.Boundary.Canonical: dfx CanisterCall
  -- excludable=True), so these reclassify to ExternalEffectBoundary (non-blocking),
  -- not UnclassifiedForeign (claim-blocking Unknown).
  , (",libic0",                    "CanisterCall")
  , (",global_registry_runtime",   "CanisterCall")
  ]

-- Benign foreign primitives that are TOTAL, DETERMINISTIC for coverage purposes,
-- and ALWAYS harness-executable: pure string machinery (scheme string-concat /
-- string-unpack) and the libidris2_support shims the Chez/RefC runtime threads
-- through ordinary pure-looking code (string marshalling, NULL checks, error
-- strings, the buffered putStr the test harness itself runs). Reaching one of
-- these opens NO untestable hole — the harness executes them on every test — so a
-- path that transitively touches them must stay a ReachableObligation. This is
-- still a COMPILER FACT keyed on the cc string (the prim is identified by name),
-- not a human value-weight: the narrow soundness guarantee below is preserved for
-- GENUINE effect holes (process / network / file / exit / clock / unrecognised).
benignPrimSubstrings : List String
benignPrimSubstrings =
  [ "string-concat"
  , "string-unpack"
  , "idris2_putStr"
  , "idris2_getString"
  , "idris2_isNull"
  , "idris2_strerror"
  -- getenv / blodwen-arg(-count): total, harness-executable reads of the process
  -- environment and command-line argv. Reading them opens no untestable hole — the
  -- path runs (the test process has an env and an argv).
  , "getenv"
  , "blodwen-arg"
  -- Standard OUTPUT stream handles (stdout/stderr) and the cwd read: console output
  -- the test harness itself performs on every run (same class as idris2_putStr).
  -- Getting the handle / reading cwd opens no untestable hole — the path runs.
  -- (stdin is deliberately NOT here: a blocking input read is harness-unexecutable
  -- and is classified as a recognised FileSystemIO boundary below.)
  , "idris2_stdout"
  , "idris2_stderr"
  , "idris2_currentDirectory"
  -- fflush: flushing a stream buffer is console-output housekeeping the harness runs
  -- on every print; opens no untestable hole.
  , "fflush"
  -- idris2_free: runtime memory housekeeping with no observable effect; always runs.
  , "idris2_free"
  -- Clock reads: idris2_time / blodwen-clock-second / blodwen-is-time? return a
  -- value on every call. Non-determinism of the VALUE does not make the PATH
  -- untestable — the harness executes the call — so for path-reachability coverage
  -- these are benign.
  , "idris2_time"
  , "blodwen-clock"
  , "blodwen-is-time"
  -- getPID: a total, always-succeeding read of the current process id (same
  -- class as getenv / the clock reads — the value varies, the PATH always
  -- runs). Untriaged it classified pid-keyed scratch-file helpers (e.g.
  -- Luci.Commands.Parity.pidScratch and its test) as claim-blocking
  -- UnknownClassification, holding an otherwise-passing measurement
  -- inadmissible.
  , "idris2_getPID"
  ]

-- The boundary tag for a ForeignDef. A known effect primitive (popen2/...) maps to
-- its precise tag; a known BENIGN primitive (string-concat/putStr/...) opens no
-- hole and maps to PureComputation; ANY OTHER %foreign maps to
-- UnclassifiedForeign(<cc>) — NEVER to "no boundary". This is the soundness
-- guarantee: every UNRECOGNISED FFI hole is captured (a ForeignDef IS a hole by
-- definition unless it is on the audited benign list), so a new external call can
-- never be silently mistaken for pure, harness-testable code. The cc string is
-- carried so a new hole is visible and triageable, never lost.
ccBoundary : List String -> String
ccBoundary ccs =
  if any (\sub => any (String.isInfixOf sub) ccs) benignPrimSubstrings
    then "PureComputation"
    else case find (\(sub, _) => any (String.isInfixOf sub) ccs) boundaryPrimSubstrings of
           Just (_, tag) => tag
           Nothing       => "UnclassifiedForeign(" ++ (case ccs of (c :: _) => c; [] => "?") ++ ")"

-- The boundary a single def directly opens. A ForeignDef is ALWAYS a hole (its
-- tag is precise or UnclassifiedForeign); a non-foreign def opens nothing here.
directBoundary : {auto c : Ref Ctxt Defs} -> Name -> Core (Maybe String)
directBoundary n =
  do defs <- get Ctxt
     Just gdef <- lookupCtxtExact n (gamma defs)
          | Nothing => pure Nothing
     case definition gdef of
       ForeignDef _ ccs => pure (Just (ccBoundary ccs))
       _                => pure Nothing

-- The strongest external boundary `n` transitively reaches (PureComputation = none),
-- via a depth-bounded DFS over refersTo. `seen` guards cycles; `fuel` bounds depth
-- (the call graph is large, but a path to a foreign prim is shallow in practice).
effectBoundaryOf : {auto c : Ref Ctxt Defs} ->
                   (fuel : Nat) -> (seen : NameMap Bool) -> Name ->
                   Core String
effectBoundaryOf Z _ _ = pure "PureComputation"
effectBoundaryOf (S fuel) seen n =
  case lookup n seen of
    Just _  => pure "PureComputation"   -- cycle / already visited on this branch
    Nothing =>
      do Just b <- directBoundary n
              | Nothing => walkCallees
         pure b
  where
    walkCallees : Core String
    walkCallees =
      do defs <- get Ctxt
         Just gdef <- lookupCtxtExact n (gamma defs)
              | Nothing => pure "PureComputation"
         let callees = keys (refersTo gdef)
         let seen' = insert n True seen
         go callees seen'
      where
        go : List Name -> NameMap Bool -> Core String
        go [] _ = pure "PureComputation"
        go (m :: ms) sn =
          do b <- effectBoundaryOf fuel sn m
             if b /= "PureComputation"
                then pure b
                else go ms sn

functionPathEntry : {auto c : Ref Ctxt Defs} -> Name -> Core (Maybe (String, String))
functionPathEntry n =
  do defs <- get Ctxt
     Just gdef <- lookupCtxtExact n (gamma defs)
          | Nothing => pure Nothing
     case definition gdef of
       PMDef _ _ treeCT _ _ =>
         let functionName = fullShowName n
         in do treeCTFull <- full (gamma defs) treeCT
               let (paths, _) = collectPathResults functionName 0 treeCTFull
               -- Fact-grounded boundary: a compiler-computed call-graph property,
               -- emitted so the consumer can exclude only harness-unexecutable
               -- paths with this witness (never an observer judgment).
               boundary <- effectBoundaryOf 64 empty n
               pure $ Just
                    ( functionName
                    , jsonObject
                        [ jsonField "function_name" (jsonString functionName)
                        , jsonField "effect_boundary" (jsonString boundary)
                        , jsonField "paths" (jsonArray (pathResultsJson functionName 0 paths))
                        ]
                    )
       _ => pure Nothing

functionPathsJson : {auto c : Ref Ctxt Defs} -> Name -> Core (Maybe String)
functionPathsJson n = map (map snd) (functionPathEntry n)

collectFunctionPathsJson : {auto c : Ref Ctxt Defs} -> List Name -> Core (List String)
collectFunctionPathsJson [] = pure []
collectFunctionPathsJson (n :: ns) =
  do here <- functionPathsJson n
     there <- collectFunctionPathsJson ns
     pure $ maybe there (\entry => entry :: there) here

collectFunctionPathEntries : {auto c : Ref Ctxt Defs} -> List Name -> Core (List (String, String))
collectFunctionPathEntries [] = pure []
collectFunctionPathEntries (n :: ns) =
  do here <- functionPathEntry n
     there <- collectFunctionPathEntries ns
     pure $ maybe there (\entry => entry :: there) here

pathPartsFile : String -> String
pathPartsFile fn = fn ++ ".parts"

functionNameField : String
functionNameField = "\"function_name\": \""

extractFunctionNameEntry : String -> Maybe String
extractFunctionNameEntry entry
    = case findSubstring functionNameField entry of
           Nothing => Nothing
           Just start =>
             let rest = substr (cast start + length functionNameField)
                               (minus (minus (length entry) start) (length functionNameField))
                               entry
             in case span (/= '"') rest of
                     (fn, _) => if fn == "" then Nothing else Just fn
  where
    findSubstring : String -> String -> Maybe Nat
    findSubstring needle haystack = go 0
      where
        maxStart : Nat
        maxStart = minus (length haystack) (length needle)

        go : Nat -> Maybe Nat
        go i = if i > maxStart
                  then Nothing
                  else if isPrefixOf needle (substr (cast i) (minus (length haystack) i) haystack)
                          then Just i
                          else go (S i)

dedupeFunctionEntries : List String -> List String
dedupeFunctionEntries = reverse . snd . foldl keep (SortedMap.empty, [])
  where
    keep : (SortedMap String (), List String) -> String -> (SortedMap String (), List String)
    keep (seen, acc) entry =
      case extractFunctionNameEntry entry of
           Just fn => case SortedMap.lookup fn seen of
                           Just _ => (seen, acc)
                           Nothing => (SortedMap.insert fn () seen, entry :: acc)
           Nothing => (seen, entry :: acc)

collectMissingFunctionPathsJson : {auto c : Ref Ctxt Defs} ->
                                  SortedMap String () -> List Name -> Core (List String)
collectMissingFunctionPathsJson _ [] = pure []
collectMissingFunctionPathsJson seen (n :: ns) =
  do let fn = fullShowName n
     rest <- collectMissingFunctionPathsJson seen ns
     case SortedMap.lookup fn seen of
          Just _ => pure rest
          Nothing =>
            do here <- functionPathsJson n
               pure $ maybe rest (\entry => entry :: rest) here

writePathsJsonPayload : String -> List String -> Core ()
writePathsJsonPayload fn functions
    = do let payload =
               jsonObject
                 [ jsonField "compiler_version" (jsonString (showVersion False version))
                 , jsonField "export_kind" (jsonString "canonical_intrafunction_paths")
                 , jsonField "path_schema_version" (show 1)
                 , jsonField "functions" (jsonArray functions)
                 ]
         Right () <- coreLift $ writeFile fn payload
               | Left err => throw (FileErr fn err)
         pure ()

dumpPathsJson : {auto c : Ref Ctxt Defs} -> String -> List Name -> Core ()
dumpPathsJson fn ns
    = do functions <- collectFunctionPathsJson ns
         writePathsJsonPayload fn functions

appendPathsJsonParts : {auto c : Ref Ctxt Defs} -> String -> List Name -> Core ()
appendPathsJsonParts fn ns
    = do functions <- collectFunctionPathEntries ns
         let partsFn = pathPartsFile fn
         traverse_ (\(_, entry) =>
                      do Right () <- coreLift $ appendFile partsFn (entry ++ "\n")
                              | Left err => throw (FileErr partsFn err)
                         pure ())
                   functions

finalizePathsJson : {auto c : Ref Ctxt Defs} -> String -> List Name -> Core ()
finalizePathsJson fn ns
    = do let partsFn = pathPartsFile fn
         hasParts <- coreLift $ exists partsFn
         existing <- if hasParts then Core.readFile partsFn else pure ""
         let parts = dedupeFunctionEntries $ filter (/= "") (lines existing)
         let seen = foldl (\acc, entry =>
                             case extractFunctionNameEntry entry of
                                  Just fn => SortedMap.insert fn () acc
                                  Nothing => acc)
                          SortedMap.empty parts
         missing <- collectMissingFunctionPathsJson seen ns
         writePathsJsonPayload fn (parts ++ missing)

isSyntheticPathHelperName : Name -> Bool
isSyntheticPathHelperName n = String.isInfixOf ".{" (fullShowName n)

||| A record field generates TWO defs: the plain selector `Ns.field`
||| (`UN (Basic f)`) and the postfix-projection `Ns.(.field)` (`UN (Field f)`).
||| The plain selector's body is just a thin wrapper that calls the projection, so
||| EVERY path it has is also a path of the projection. Emitting both as separate
||| path obligations double-counts the field AND — because real code reaches the
||| projection through whichever surface syntax it used (postfix `r.field` lowers to
||| the `(.field)` projection directly) — leaves the plain-selector copy structurally
||| unreachable whenever the codebase only writes `r.field`. Treat the plain selector
||| as a duplicate of its `(.field)` projection and drop it from the path-name set so
||| each field contributes exactly one (the canonical projection) obligation.
isRecordSelectorWrapper : {auto c : Ref Ctxt Defs} -> Name -> Core Bool
isRecordSelectorWrapper (NS ns (UN (Basic f)))
    = do defs <- get Ctxt
         pure $ isJust !(lookupCtxtExact (NS ns (UN (Field f))) (gamma defs))
isRecordSelectorWrapper _ = pure False

isCurrentModulePathName : {auto c : Ref Ctxt Defs} -> Name -> Core Bool
isCurrentModulePathName n
    = do let False = isSyntheticPathHelperName n
               | _ => pure False
         False <- isRecordSelectorWrapper n
              | _ => pure False
         defs <- get Ctxt
         Just gdef <- lookupCtxtExact n (gamma defs)
              | Nothing => pure False
         case definition gdef of
              PMDef {} => pure (multiplicity gdef /= erased)
              _ => pure False

currentModulePathNames : {auto c : Ref Ctxt Defs} -> Core (List Name)
currentModulePathNames
    = do defs <- get Ctxt
         filterM isCurrentModulePathName (keys (toSave defs))

moduleOrigin : GlobalDef -> Maybe ModuleIdent
moduleOrigin gdef
    = do (PhysicalIdrSrc mod, _, _) <- isNonEmptyFC (location gdef)
            | _ => Nothing
         pure mod

nameModuleMatches : List ModuleIdent -> Name -> Bool
nameModuleMatches [] _ = False
nameModuleMatches (mod :: mods) n =
    let ns = fst (splitNS n)
        mi = miAsNamespace mod
    -- `isParentOf ns mi` keeps names whose namespace IS the module (plain defs and
    -- record-selector wrappers `Mod.field`). But a record-field PROJECTION lives one
    -- namespace DEEPER — `Mod.Record.(.field)` — so its namespace is a CHILD of the
    -- module, not equal to it. Also accept that direction (`isParentOf mi ns`) so the
    -- canonical `(.field)` projection is kept as a path obligation under its module.
    in isParentOf ns mi || isParentOf mi ns || nameModuleMatches mods n

isPackagePathName : {auto c : Ref Ctxt Defs} -> List ModuleIdent -> Name -> Core Bool
isPackagePathName [] _ = pure False
isPackagePathName mods n
    = do let False = isSyntheticPathHelperName n
               | _ => pure False
         False <- isRecordSelectorWrapper n
              | _ => pure False
         defs <- get Ctxt
         Just gdef <- lookupCtxtExact n (gamma defs)
              | Nothing => pure False
         case definition gdef of
              PMDef {} =>
                pure $ multiplicity gdef /= erased
                    && (nameModuleMatches mods n
                        || maybe False (`elem` mods) (moduleOrigin gdef))
              _ => pure False

currentPackagePathNames : {auto c : Ref Ctxt Defs} -> Core (List Name)
currentPackagePathNames
    = do sopts <- getSession
         case pathCoverageModules sopts of
              [] => pure []
              mods =>
                do defs <- get Ctxt
                   names <- allNames (gamma defs)
                   filterM (isPackagePathName mods) names

export
snapshotCurrentModulePathsJson : {auto c : Ref Ctxt Defs} -> String -> Core ()
snapshotCurrentModulePathsJson fn
    = do modulePathNs <- currentModulePathNames
         appendPathsJsonParts fn modulePathNs


export
nonErased : {auto c : Ref Ctxt Defs} ->
            Name -> Core Bool
nonErased n
    = do defs <- get Ctxt
         Just gdef <- lookupCtxtExact n (gamma defs)
              | Nothing => pure True
         pure (multiplicity gdef /= erased)

export
addForeignImpl : {auto c : Ref Ctxt Defs} ->
             Name -> Core ()
addForeignImpl n
    = do defs <- get Ctxt
         Just def <- lookupCtxtExact n (gamma defs)        | Nothing => pure ()
         let Just (MkForeign cs atys retty) = compexpr def | _ => pure ()
         let xs = map snd $ filter (\x => fst x == n) defs.options.foreignImpl
         setCompiled n (MkForeign (xs ++ cs) atys retty)

-- Get the names of the functions we're exporting to the given back end, and
-- the corresponding name it will have when exported.
getExported : String -> NameMap (List (String, String)) -> List (Name, String)
getExported backend all
    = mapMaybe isExp (toList all)
  where
    -- If the name/convention pair matches the backend, keep the name
    isExp : (Name, List (String, String)) -> Maybe (Name, String)
    isExp (n, cs)
        = do fn <- lookup backend cs
             pure (n, fn)

-- Find all the names which need compiling, from a given expression, and compile
-- them to CExp form (and update that in the Defs).
-- Return the names, the type tags, and a compiled version of the expression
export
getCompileDataWith : {auto c : Ref Ctxt Defs} ->
                     List String -> -- which FFI(s), if compiling foreign exports
                     (doLazyAnnots : Bool) ->
                     UsePhase -> ClosedTerm -> Core CompileData
getCompileDataWith exports doLazyAnnots phase_in tm_in
    = do log "compile.execute" 10 $ "Getting compiled data for: " ++ show tm_in
         sopts <- getSession
         let phase = foldl {t=List} (flip $ maybe id max) phase_in $
                       [ Cases <$ dumpcases sopts
                       , Cases <$ dumpcasesjson sopts
                       , Cases <$ dumppathsjson sopts
                       , Lifted <$ dumplifted sopts
                       , ANF <$ dumpanf sopts
                       , VMCode <$ dumpvmcode sopts
                       ]

         -- When we compile a REPL expression, there may be leftovers holes in it.
         -- Turn these into runtime errors.
         let metas = addMetas True empty tm_in
         for_ (keys metas) $ \ metanm =>
             do defs <- get Ctxt
                Just gdef <- lookupCtxtExact metanm (gamma defs)
                  | Nothing => log "compile.execute" 50 $ unwords
                                    [ "Couldn't find"
                                    , show metanm
                                    , "(probably impossible)"]
                let Hole _ _ = definition gdef
                  | _ => pure ()
                let fulln = fullname gdef
                let cexp = MkError $ CCrash emptyFC
                         $ "Encountered unimplemented hole " ++ show fulln
                ignore $ addDef metanm ({ compexpr := Just cexp
                                        , namedcompexpr := Just (forgetDef cexp)
                                        } gdef)

         defs <- get Ctxt
         let refs  = getRefs (Resolved (-1)) tm_in
         exported <- if isNil exports
                 then pure []
                 else getExports defs
         log "compile.export" 25 "exporting: \{show $ map fst exported}"
         let ns = keys (mergeWith const metas refs) ++ map fst exported
         log "compile.execute" 70 $
           "Found names: " ++ concat (intersperse ", " $ map show $ ns)
         tm <- toFullNames tm_in
         natHackNames' <- traverse toResolvedNames natHackNames
         -- make an array of Bools to hold which names we've found (quicker
         -- to check than a NameMap!)
         asize <- getNextEntry
         arr <- coreLift $ newArray asize

         defs <- get Ctxt
         logTime 2 "Get names" $ getAllDesc (natHackNames' ++ ns) arr defs

         let entries = catMaybes !(coreLift (toList arr))
         let allNs = map (Resolved . fst) entries
         cns <- traverse toFullNames allNs
         log "compile.execute" 30 $
           "All names: " ++ concat (intersperse ", " $ map show $ zip allNs cns)

         -- Do a round of merging/arity fixing for any names which were
         -- unknown due to cyclic modules (i.e. declared in one, defined in
         -- another)
         rcns <- filterM nonErased cns
         log "compile.execute" 40 $
           "Kept: " ++ concat (intersperse ", " $ map show rcns)

         logTime 2 "Merge lambda" $ traverse_ mergeLamDef rcns
         logTime 2 "Fix arity" $ traverse_ fixArityDef rcns
         logTime 2 "Fix foreign bindings" $ traverse_ addForeignImpl rcns
         compiledtm <- fixArityExp !(compileExp tm)

         (cseDefs, csetm) <- logTime 2 "CSE" $ cse rcns compiledtm

         -- Add intrinsic constructors (see Compiler.Opts.Constructor)
         let cseDefs = intrinsicCons ++ cseDefs

         namedDefs <- logTime 2 "Forget names" $
           traverse getNamedDef cseDefs

         let mainname = MN "__mainExpression" 0
         (liftedtm, ldefs) <- liftBody {doLazyAnnots} mainname csetm

         lifted_in <- if phase >= Lifted
                         then logTime 2 "Lambda lift" $
                              traverse (lambdaLift doLazyAnnots) cseDefs
                         else pure []

         let lifted = (mainname, MkLFun Scope.empty Scope.empty liftedtm) ::
                      (ldefs ++ concat lifted_in)

         anf <- if phase >= ANF
                   then logTime 2 "Get ANF" $ traverse (\ (n, d) => pure (n, !(toANF d))) lifted
                   else pure []
         vmcode <- if phase >= VMCode
                      then logTime 2 "Get VM Code" $ pure (allDefs anf)
                      else pure []

         defs <- get Ctxt
         whenJust (dumpcases sopts) $ \ f =>
            do coreLift $ putStrLn $ "Dumping case trees to " ++ f
               dumpIR f (map (\(n, _, def) => (n, def)) namedDefs)

         whenJust (dumpcasesjson sopts) $ \ f =>
            do coreLift $ putStrLn $ "Dumping case trees as JSON to " ++ f
               dumpIRJson f (map (\(n, _, def) => (n, def)) namedDefs)

         whenJust (dumppathsjson sopts) $ \ f =>
            do packagePathNs <- currentPackagePathNames
               modulePathNs <- currentModulePathNames
               let pathNs0 = if isNil packagePathNs
                               then if isNil modulePathNs then rcns else modulePathNs
                               else packagePathNs
               -- Drop record-selector wrappers (the plain `Ns.field` duplicate of the
               -- `Ns.(.field)` projection) so each field is one canonical obligation.
               pathNs <- filterM (map not . isRecordSelectorWrapper) pathNs0
               coreLift $ putStrLn $ "Dumping canonical paths as JSON to " ++ f
               finalizePathsJson f pathNs

         whenJust (dumplifted sopts) $ \ f =>
            do coreLift $ putStrLn $ "Dumping lambda lifted defs to " ++ f
               dumpIR f lifted

         whenJust (dumpanf sopts) $ \ f =>
            do coreLift $ putStrLn $ "Dumping ANF defs to " ++ f
               dumpIR f anf

         whenJust (dumpvmcode sopts) $ \ f =>
            do coreLift $ putStrLn $ "Dumping VM defs to " ++ f
               dumpIR f vmcode

         -- We're done with our minimal context now, so put it back the way
         -- it was. Back ends shouldn't look at the global context, because
         -- it'll have to decode the definitions again.
         traverse_ replaceEntry entries
         pure (MkCompileData csetm exported namedDefs lifted anf vmcode)
  where
    lookupBackend :
        List String ->
        (Name, List (String, String)) ->
        Maybe (Name, String)
    lookupBackend [] _ = Nothing
    lookupBackend (b :: bs) (n, exps) = case find (\(b', _) => b == b') exps of
        Just (_, exp) => Just (n, exp)
        Nothing => lookupBackend bs (n, exps)

    getExports : Defs -> Core (List (Name, String))
    getExports defs = traverse (\(n, exp) => pure (!(resolved defs.gamma n), exp)) $
        mapMaybe (lookupBackend exports) (toList defs.foreignExports)

-- Find all the names which need compiling, from a given expression, and compile
-- them to CExp form (and update that in the Defs).
-- Return the names, the type tags, and a compiled version of the expression
export
getCompileData : {auto c : Ref Ctxt Defs} ->
                 (doLazyAnnots : Bool) ->
                 UsePhase -> ClosedTerm -> Core CompileData
getCompileData = getCompileDataWith []

export
compileTerm : {auto c : Ref Ctxt Defs} ->
              ClosedTerm -> Core ClosedCExp
compileTerm tm_in
    = do tm <- toFullNames tm_in
         fixArityExp !(compileExp tm)

compDef : {auto c : Ref Ctxt Defs} -> Name -> Core (Maybe (Name, FC, CDef))
compDef n = do
  defs <- get Ctxt
  Just def <- lookupCtxtExact n (gamma defs) | Nothing => pure Nothing
  let Just cexpr =  compexpr def             | Nothing => pure Nothing
  pure $ Just (n, location def, cexpr)

export
getIncCompileData : {auto c : Ref Ctxt Defs} ->
                    (doLazyAnnots : Bool) ->
                    UsePhase -> Core CompileData
getIncCompileData doLazyAnnots phase
    = do defs <- get Ctxt
         -- Compile all the names in 'toIR', since those are the ones defined
         -- in the current source file
         let ns = keys (toIR defs)
         cns <- traverse toFullNames ns
         rcns <- filterM nonErased cns
         cseDefs <- catMaybes <$> traverse compDef rcns

         namedDefs <- traverse getNamedDef cseDefs

         lifted_in <- if phase >= Lifted
                         then logTime 2 "Lambda lift" $
                              traverse (lambdaLift doLazyAnnots) cseDefs
                         else pure []
         let lifted = concat lifted_in
         anf <- if phase >= ANF
                   then logTime 2 "Get ANF" $ traverse (\ (n, d) => pure (n, !(toANF d))) lifted
                   else pure []
         vmcode <- if phase >= VMCode
                      then logTime 2 "Get VM Code" $ pure (allDefs anf)
                      else pure []
         sopts <- getSession
         whenJust (dumppathsjson sopts) $ \ f =>
            do rcns' <- filterM (map not . isRecordSelectorWrapper) rcns
               appendPathsJsonParts f rcns'
         pure (MkCompileData (CErased emptyFC) [] namedDefs lifted anf vmcode)

-- Some things missing from Prelude.File


||| check to see if a given file exists
export
exists : String -> IO Bool
exists f
    = do Right ok <- openFile f Read
             | Left err => pure False
         closeFile ok
         pure True
-- Select the most preferred target from an ordered list of choices and
-- parse the calling convention into a backend/target for the call, and
-- a comma separated list of any other location data. For example
-- the chez backend would supply ["scheme,chez", "scheme", "C"]. For a function with
-- more than one string, a string with "scheme" would be preferred over one
-- with "C" and "scheme,chez" would be preferred to both.
-- e.g. "scheme:display" - call the scheme function 'display'
--      "C:puts,libc,stdio.h" - call the C function 'puts' which is in
--      the library libc and the header stdio.h
-- Returns Nothing if there is no match.
export
parseCC : List String -> List String -> Maybe (String, List String)
parseCC [] _ = Nothing
parseCC (target::ts) strs = findTarget target strs <|> parseCC ts strs
  where
    getOpts : String -> List String
    getOpts "" = []
    getOpts str
        = case span (/= ',') str of
               (opt, "") => [opt]
               (opt, rest) => opt :: getOpts (assert_total (strTail rest))
    hasTarget : String -> String -> Bool
    hasTarget target str = case span (/= ':') str of
                            (targetSpec, _) => targetSpec == target
    findTarget : String -> List String -> Maybe (String, List String)
    findTarget target [] = Nothing
    findTarget target (s::xs) = if hasTarget target s
                                  then case span (/= ':') s of
                                        (t, "") => Just (trim t, [])
                                        (t, opts) => Just (trim t, map trim (getOpts
                                                                  (assert_total (strTail opts))))
                                  else findTarget target xs

export
dylib_suffix : String
dylib_suffix
    = cond [(elem os $ the (List String) ["windows", "mingw32", "cygwin32"], "dll"),
            (os == "darwin", "dylib")]
           "so"

export
locate : {auto c : Ref Ctxt Defs} ->
         String -> Core (String, String)
locate libspec
    = do -- Attempt to turn libspec into an appropriate filename for the system
         let fname
              = case words libspec of
                     [] => ""
                     [fn] => if '.' `elem` unpack fn
                                then fn -- full filename given
                                else -- add system extension
                                     fn ++ "." ++ dylib_suffix
                     (fn :: ver :: _) =>
                          -- library and version given, build path name as
                          -- appropriate for the system
                          cond [(dylib_suffix == "dll",
                                      fn ++ "-" ++ ver ++ ".dll"),
                                (dylib_suffix == "dylib",
                                      fn ++ "." ++ ver ++ ".dylib")]
                                (fn ++ "." ++ dylib_suffix ++ "." ++ ver)

         fullname <- catch (findLibraryFile fname)
                           (\err => -- assume a system library so not
                                    -- in our library path
                                    pure fname)
         pure (fname, fullname)

export
copyLib : (String, String) -> Core ()
copyLib (lib, fullname)
    = if lib == fullname
         then pure ()
         else do Right bin <- coreLift $ readFromFile fullname
                    | Left err => pure () -- assume a system library installed globally
                 Right _ <- coreLift $ writeToFile lib bin
                    | Left err => throw (FileErr lib err)
                 pure ()


-- parses `--directive extraRuntime=/path/to/defs.scm` options for textual inclusion in generated
-- source. Use with `%foreign "scheme:..."` declarations to write runtime-specific scheme calls.
export
getExtraRuntime : List String -> Core String
getExtraRuntime directives
    = do fileContents <- traverse Core.readFile paths
         pure $ concat $ intersperse "\n" fileContents
  where
    getArg : String -> Maybe String
    getArg directive =
      let (k,v) = break (== '=') directive
      in
        if (trim k) == "extraRuntime"
          then Just $ trim $ substr 1 (length v) v
          else Nothing

    paths : List String
    paths = nub $ mapMaybe getArg $ reverse directives

-- parses `--directive lazy=weakMemo` option for turning on weak memoisation of lazy values
-- (if supported by a backend).
-- This particular form of the directive string is chosen to be able to pass different variants
-- in the future (say, for strong memoisation, or turning laziness off).
export
getWeakMemoLazy : List String -> Bool
getWeakMemoLazy = elem "lazy=weakMemo"

||| Cast implementations. Values of `ConstantPrimitives` can
||| be used in a call to `castInt`, which then determines
||| the cast implementation based on the given pair of
||| constants.
public export
record ConstantPrimitives' str where
  constructor MkConstantPrimitives
  charToInt    : IntKind -> str -> Core str
  intToChar    : IntKind -> str -> Core str
  stringToInt  : IntKind -> str -> Core str
  intToString  : IntKind -> str -> Core str
  doubleToInt  : IntKind -> str -> Core str
  intToDouble  : IntKind -> str -> Core str
  intToInt     : IntKind -> IntKind -> str -> Core str

public export
ConstantPrimitives : Type
ConstantPrimitives = ConstantPrimitives' String

||| Implements casts from and to integral types by using
||| the implementations from the provided `ConstantPrimitives`.
export
castInt :  ConstantPrimitives' str
        -> PrimType
        -> PrimType
        -> str
        -> Core str
castInt p from to x =
  case ((from, intKind from), (to, intKind to)) of
       ((CharType, _)  , (_, Just k)) => p.charToInt k x
       ((StringType, _), (_, Just k)) => p.stringToInt k x
       ((DoubleType, _), (_, Just k)) => p.doubleToInt k x
       ((_, Just k), (CharType, _))   => p.intToChar k x
       ((_, Just k), (StringType, _)) => p.intToString k x
       ((_, Just k), (DoubleType, _)) => p.intToDouble k x
       ((_, Just k1), (_, Just k2))   => p.intToInt k1 k2 x
       _ => throw $ InternalError $ "invalid cast: + " ++ show from ++ " + ' -> ' + " ++ show to
