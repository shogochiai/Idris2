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
  labels : List String   -- branch_label chain (root->leaf); input to stable_key

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
prependStep functionName caseIdx branchIdx branchLabel origin sourceSpan (MkPathResult terminal steps labels) =
  let step = stepJson functionName caseIdx branchIdx branchLabel origin sourceSpan
  in MkPathResult terminal (step :: steps) (branchLabel :: labels)

mutual
  collectPathResults : String -> Nat -> CaseTree vars -> (List PathResult, Nat)
  collectPathResults functionName nextCase (Case _ _ scTy alts) =
    let caseIdx = nextCase
        sourceSpan = fcToMaybeString (getLoc scTy)
    in collectAltPathResults functionName caseIdx 0 (S nextCase) sourceSpan alts
  collectPathResults functionName nextCase leaf =
    ([MkPathResult (pathTerminalForLeaf leaf) [] []], nextCase)

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

-- Erase every "<digits>:<digits>:" source-position run from a declaration id,
-- keeping the nesting shape. Nested and local declarations are named with an
-- encoded source position, which makes them unique within a run but renames them
-- whenever anything above them moves; erasing it here gives the position-
-- independent half of the identity (see `stableKey`). Emitting the erased form
-- means the definition of "position-independent" lives in one place -- here --
-- rather than being re-derived by each reader of the JSON.
eraseLineCol : String -> String
eraseLineCol s = pack (go (unpack s))
  where
    isDigitChar : Char -> Bool
    isDigitChar c = c >= '0' && c <= '9'
    dropLineColRun : List Char -> Maybe (List Char)
    dropLineColRun cs =
      let (d1, rest1) = span isDigitChar cs in
      case (d1, rest1) of
        ([], _) => Nothing
        (_, ':' :: rest1') =>
          let (d2, rest2) = span isDigitChar rest1' in
          case (d2, rest2) of
            ([], _) => Nothing
            (_, ':' :: rest2') => Just rest2'
            _ => Nothing
        _ => Nothing
    go : List Char -> List Char
    go [] = []
    go cs@(c :: rest) =
      if isDigitChar c
        then case dropLineColRun cs of
               Just after => go after
               Nothing    => c :: go rest
        else c :: go rest

joinLabels : List String -> String
joinLabels [] = "-"
joinLabels [x] = x
joinLabels (x :: xs) = x ++ "," ++ joinLabels xs

-- The inter-run COMPARISON key, emitted alongside `path_id`:
--   (declaration, position erased) | branch_label chain | ordinal among siblings
-- A `path_id` must distinguish two declarations WITHIN one run, which needs the
-- source position; matching the same obligation ACROSS two runs needs position-
-- independence. One string cannot do both, so both are emitted: `path_id` keeps
-- the position (and may churn), `stable_key` erases it (and does not).
stableKey : String -> List String -> Nat -> String
stableKey functionName labels ordinal =
  eraseLineCol functionName ++ "|" ++ joinLabels labels ++ "|" ++ show ordinal

pathResultJson : String -> Nat -> Nat -> PathResult -> String
pathResultJson functionName pathIdx ordinal (MkPathResult terminal steps labels) =
  jsonObject $
    [ jsonField "path_id" (jsonString (functionName ++ "#p" ++ show pathIdx))
    , jsonField "stable_key" (jsonString (stableKey functionName labels ordinal))
    , jsonField "classification" (jsonString (classification terminal))
    , jsonField "terminal_kind" (jsonString (terminalKind terminal))
    , jsonField "terminal_origin" (jsonString (terminalOrigin terminal))
    , jsonField "path_length" (show (length steps))
    , jsonField "steps" (jsonArray steps)
    ] ++ maybe [] (\clauseId => [jsonField "terminal_clause_id" (show clauseId)]) (terminalClauseId terminal)
      ++ maybe [] (\msg => [jsonField "terminal_message" (jsonString msg)]) (terminalMessage terminal)

-- ordinal (D4) = occurrence index of this path among siblings sharing the same
-- branch_label chain within this declaration (functionName is constant per entry,
-- so grouping on the label chain is exactly "same module + decl shape + labels").
pathResultsJson : String -> Nat -> List PathResult -> List String
pathResultsJson functionName startIdx paths = go SortedMap.empty startIdx paths
  where
    go : SortedMap String Nat -> Nat -> List PathResult -> List String
    go _ _ [] = []
    go seen idx (path :: rest) =
      let key  = joinLabels (labels path)
          ord  = maybe 0 id (SortedMap.lookup key seen)
          seen' = SortedMap.insert key (S ord) seen
      in pathResultJson functionName idx ord path :: go seen' (S idx) rest
-- Make each declaration id unique within a run. `show` renders a `CaseBlock`
-- without its index (`case block in f`), so two case blocks in one function --
-- and `if`/`then`/`else` and record update, which desugar to case blocks -- share
-- a name; the export then merges them and drops one declaration's paths. We
-- append a source-order ordinal `~<k>`, but ONLY to names that actually have a
-- same-named sibling, so a unique name (top-level function, where-local, lone
-- case block) is left exactly as it was.
--
-- The ordinal counts same-named declarations emitted BEFORE this one. The
-- alternative -- splicing the `CaseBlock` index back in -- looks simpler and is
-- wrong: that index is assigned globally, so inserting an unrelated declaration
-- renumbers it (observed: two siblings 16 and 39 became 151 and 174), which would
-- make `stable_key` churn on edits elsewhere in the file. Their relative ORDER is
-- what survives such an edit, so the ordinal is derived from that. `eraseLineCol`
-- does not strip `~<k>`, so the emitted `stable_key` stays distinct between
-- siblings while remaining position-independent.
disambiguate : List Name -> List String
disambiguate ns =
  let names  = map fullShowName ns
      counts = foldl (\m, s => SortedMap.insert s (S (maybe 0 id (SortedMap.lookup s m))) m) SortedMap.empty names
  in reverse (snd (foldl (step counts) (SortedMap.empty, []) names))
  where
    step : SortedMap String Nat -> (SortedMap String Nat, List String) -> String ->
           (SortedMap String Nat, List String)
    step counts (seen, acc) nm =
      let k     = maybe 0 id (SortedMap.lookup nm seen)
          seen' = SortedMap.insert nm (S k) seen
          disp  = if maybe False (> 1) (SortedMap.lookup nm counts)
                     then nm ++ "~" ++ show k
                     else nm
      in (seen', disp :: acc)

functionPathEntry : {auto c : Ref Ctxt Defs} -> Name -> String -> Core (Maybe (String, String))
functionPathEntry n dispName =
  do defs <- get Ctxt
     Just gdef <- lookupCtxtExact n (gamma defs)
          | Nothing => pure Nothing
     case definition gdef of
       -- Read the runtime tree, not the compile-time one. Only the runtime tree
       -- materializes the catch-all the compiler inserts for a non-exhaustive
       -- `partial` function (an `Unmatched "Unhandled input..."` default), which
       -- is what the classification below reports as a partial gap. The compile-
       -- time tree holds only the clauses the user wrote, so reading it would
       -- silently drop every such obligation. The classification machinery here
       -- (optimizer_artifact, compiler_partial_completion) is written against the
       -- lowered tree for the same reason.
       PMDef _ _ _ treeRT _ =>
         let functionName = dispName
         in do treeRTFull <- full (gamma defs) treeRT
               let (paths, _) = collectPathResults functionName 0 treeRTFull
               pure $ Just
                    ( functionName
                    , jsonObject
                        [ jsonField "function_name" (jsonString functionName)
                        , jsonField "paths" (jsonArray (pathResultsJson functionName 0 paths))
                        ]
                    )
       _ => pure Nothing

functionPathsJson : {auto c : Ref Ctxt Defs} -> Name -> String -> Core (Maybe String)
functionPathsJson n dispName = map (map snd) (functionPathEntry n dispName)

-- Disambiguate the whole name list up front -- siblings have to see each other to
-- be numbered -- then process each name with its resulting unique id.
collectFunctionPathsJson : {auto c : Ref Ctxt Defs} -> List Name -> Core (List String)
collectFunctionPathsJson ns = go (zip ns (disambiguate ns))
  where
    go : List (Name, String) -> Core (List String)
    go [] = pure []
    go ((n, d) :: rest) =
      do here <- functionPathsJson n d
         there <- go rest
         pure $ maybe there (\entry => entry :: there) here

collectFunctionPathEntries : {auto c : Ref Ctxt Defs} -> List Name -> Core (List (String, String))
collectFunctionPathEntries ns = go (zip ns (disambiguate ns))
  where
    go : List (Name, String) -> Core (List (String, String))
    go [] = pure []
    go ((n, d) :: rest) =
      do here <- functionPathEntry n d
         there <- go rest
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

-- A repeated function_name whose path records DIFFER is a collision, not a
-- duplicate. Deduping it would keep one record and silently drop the other
-- declaration's paths -- an error in the direction that looks like success, since
-- the output is still well-formed, just short. Same-content repeats (the same
-- function appended unchanged) are genuinely redundant and are dropped. On a real
-- collision return `Left fn` so the caller can fail loudly instead.
dedupeFunctionEntries : List String -> Either String (List String)
dedupeFunctionEntries = go SortedMap.empty []
  where
    go : SortedMap String String -> List String -> List String -> Either String (List String)
    go _ acc [] = Right (reverse acc)
    go seen acc (entry :: rest) =
      case extractFunctionNameEntry entry of
           Nothing => go seen (entry :: acc) rest
           Just fn => case SortedMap.lookup fn seen of
                           Just prev => if prev == entry
                                           then go seen acc rest
                                           else Left fn
                           Nothing => go (SortedMap.insert fn entry seen) (entry :: acc) rest

collectMissingFunctionPathsJson : {auto c : Ref Ctxt Defs} ->
                                  SortedMap String () -> List Name -> Core (List String)
collectMissingFunctionPathsJson seen ns = go (zip ns (disambiguate ns))
  where
    go : List (Name, String) -> Core (List String)
    go [] = pure []
    go ((n, d) :: rest) =
      do let fn = fullShowName n
         r <- go rest
         case SortedMap.lookup fn seen of
              Just _ => pure r
              Nothing =>
                do here <- functionPathsJson n d
                   pure $ maybe r (\entry => entry :: r) here

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
         parts <- case dedupeFunctionEntries (filter (/= "") (lines existing)) of
                       Right ps => pure ps
                       Left dup => throw $ InternalError $
                         "[dumppaths] duplicate function_name '" ++ dup ++
                         "' with differing path records: two declarations share " ++
                         "one id. Refusing to merge them, which would silently " ++
                         "drop one declaration's paths."
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
