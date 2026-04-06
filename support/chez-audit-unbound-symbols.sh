#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <generated.ss> [output.txt]" >&2
  exit 2
fi

ss_file="$1"
out_file="${2:-}"

python3 - "$ss_file" <<'PY' | { if [ -n "$out_file" ]; then tee "$out_file"; else cat; fi; }
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

SYNTAX = {
    "define", "lambda", "let", "let*", "letrec", "letrec*", "if", "cond",
    "case", "quote", "quasiquote", "unquote", "unquote-splicing", "begin",
    "set!", "delay", "force", "or", "and", "else", "when", "unless",
    "import", "module", "library", "load", "load-shared-object", "include",
    "parameterize", "with-exception-handler", "guard", "record-case", "syntax-rules",
}

BUILTIN_PREFIXES = (
    "blodwen-", "string-", "vector-", "bytevector-", "list-", "char-",
    "symbol-", "number-", "fx", "fl", "box", "cons", "car", "cdr", "null?",
    "eq?", "eqv?", "equal?", "not", "display", "newline", "error", "exit",
    "gensym", "open-", "close-", "read", "write", "map", "for-each", "apply",
    "make-", "hashtable-", "thread-", "mutex-", "condition-", "port-", "file-",
)

BUILTINS = {
    "#t", "#f", "...", ".", "+", "-", "*", "/", "<", ">", "<=", ">=", "=",
    "begin0", "void", "void?", "values", "call/cc", "call-with-values",
    "dynamic-wind", "define-record-type", "record-type-descriptor",
    "record-constructor-descriptor", "assertion-violation", "machine-type",
    "collect", "collect-request-handler", "collect-rendezvous", "sleep",
    "interaction-environment", "scheme-version", "getenv", "current-error-port",
    "current-output-port", "source-directories", "foreign-procedure",
    "make-ftype-pointer", "ftype-ref", "ftype-set!", "type-descriptor",
    "meta-cond", "case-lambda", "format", "printf", "fprintf", "pretty-print",
}

TOKEN_RE = re.compile(r"[A-Za-z_!$%&*+\-./:<=>?@^~][A-Za-z0-9_!$%&*+\-./:<=>?@^~]*")
DEFINE_RE = re.compile(r"\(define\s+([^\s()]+)")

def strip_strings_and_comments(src: str) -> str:
    out = []
    i = 0
    in_string = False
    while i < len(src):
        ch = src[i]
        if in_string:
            if ch == "\\":
                out.append(" ")
                i += 2
                continue
            if ch == '"':
                in_string = False
            out.append(" ")
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(" ")
            i += 1
            continue
        if ch == ";":
            while i < len(src) and src[i] != "\n":
                out.append(" ")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)

def likely_builtin(sym: str) -> bool:
    if sym in SYNTAX or sym in BUILTINS:
        return True
    if sym.startswith(BUILTIN_PREFIXES):
        return True
    if sym[0].isdigit():
        return True
    if sym.startswith("C-"):
        return True
    return False

def symbol_stem(sym: str) -> str:
    m = re.match(r"^(.*?)(?:-\d+(?:-\d+)?(?:-u--.*)?)?$", sym)
    return m.group(1) if m else sym

clean = strip_strings_and_comments(text)
defines = DEFINE_RE.findall(clean)
define_set = set(defines)

tokens = TOKEN_RE.findall(clean)
refs = []
for tok in tokens:
    if likely_builtin(tok):
        continue
    refs.append(tok)

ref_set = set(refs)
missing = sorted(sym for sym in ref_set - define_set if not likely_builtin(sym))
missing_counts = {}
for sym in refs:
    if sym in missing:
        missing_counts[sym] = missing_counts.get(sym, 0) + 1

line_map = {}
for idx, line in enumerate(text.splitlines(), 1):
    for sym in DEFINE_RE.findall(line):
        line_map.setdefault(sym, idx)

print(f"file: {path}")
print(f"defines: {len(define_set)}")
print(f"refs: {len(ref_set)}")
print(f"missing: {len(missing)}")
print()

for sym in missing:
    stem = symbol_stem(sym)
    related = [d for d in defines if symbol_stem(d) == stem or stem in d or d in sym]
    related = sorted(dict.fromkeys(related))
    print(f"MISSING {sym} refs={missing_counts.get(sym, 0)} stem={stem}")
    if related:
        for d in related[:10]:
            loc = line_map.get(d, "?")
            print(f"  related-define line={loc} symbol={d}")
    else:
        print("  related-define none")
    print()
PY
