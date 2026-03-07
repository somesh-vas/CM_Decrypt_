#ifndef ROOT_H
#define ROOT_H

#include "common.h"
#include "gf.h"

void support_gen(gf *s, const unsigned char *c);
void root(gf *out, gf *f, gf *L);
void transpose_64x64(uint64_t *out, uint64_t *in);
gf eval(gf *f, gf a);
static void layer(uint64_t *data, uint64_t *bits, int lgs);
void apply_benes(unsigned char *r, const unsigned char *bits, int rev);

int initialisation(unsigned char *secretkeys, unsigned char *ciphertexts, size_t katnum, unsigned char *sk, gf *L, gf *g);

void compute_inverses(void);
void synd(gf *out, unsigned char *r);

#endif /* ROOT_H */
