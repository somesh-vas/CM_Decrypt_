#ifndef BM_H
#define BM_H

#include "common.h"
#include "gf.h"

/*
 * Recover the error-locator polynomial from a 2T-length syndrome sequence.
 *
 * `out` receives the locator coefficients in the layout expected by the rest
 * of the CPU decode path.
 */
void bm(gf *out, gf *s);

#endif /* BM_H */
