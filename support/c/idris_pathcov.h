#ifndef __IDRIS_PATHCOV_H
#define __IDRIS_PATHCOV_H

// Set the attribution label for subsequent path hits (see idris_pathcov.c).
void idris2_enterTest(const char *label);

// Record that the given path executed, attributed to the current label.
void idris2_recordPathHit(const char *pathId);

#endif
