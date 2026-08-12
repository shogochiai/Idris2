#include "idris_pathcov.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Path-coverage runtime hooks.
//
// These are always present in libidris2_support, so a program that calls them
// links and runs whether or not it was built with path instrumentation. When
// IDRIS2_PATH_HITS is unset they are cheap no-ops; when it names a file, hits
// are appended to it as "<label>\t<path-id>" lines.
//
// Keeping the implementation here (rather than behind a compiler primitive that
// only exists under a flag) is what lets the declaration live in an ordinary
// library module: no bootstrap image needs to know about it.

static FILE *hits_file = NULL;
static int   hits_tried = 0;
static char *current_label = NULL;

static FILE *pathcov_out(void) {
  if (!hits_tried) {
    hits_tried = 1;
    const char *path = getenv("IDRIS2_PATH_HITS");
    if (path && *path) hits_file = fopen(path, "a");
  }
  return hits_file;
}

void idris2_enterTest(const char *label) {
  free(current_label);
  current_label = label ? strdup(label) : NULL;
}

void idris2_recordPathHit(const char *pathId) {
  FILE *out = pathcov_out();
  if (!out || !pathId) return;
  fprintf(out, "%s\t%s\n", current_label ? current_label : "", pathId);
  fflush(out);
}
