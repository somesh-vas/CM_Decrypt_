#ifndef ROOT_H
#define ROOT_H

#include "common.h"
#include "gf.h"

/* Build the support set from the Benes control bits encoded in the secret key. */
void support_gen(gf *s, const unsigned char *c);

/* Evaluate the locator polynomial over every support element. */
void root(gf *out, gf *f, gf *L);

/* Benes-network helpers used while reconstructing the support set. */
void transpose_64x64(uint64_t *out, uint64_t *in);
gf eval(gf *f, gf a);
void apply_benes(unsigned char *r, const unsigned char *bits, int rev);

/* Load test vectors and derive the secret-key-dependent decode state. */
int initialisation(unsigned char *secretkeys, unsigned char *ciphertexts, size_t katnum, unsigned char *sk, gf *L, gf *g);

/* Precompute inverse powers, then build per-ciphertext syndromes from them. */
void compute_inverses(void);
void synd(gf *out, unsigned char *r);

#endif /* ROOT_H */
