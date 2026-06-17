#ifndef ROOT_H
#define ROOT_H

#include "common.h"
#include "gf.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Build the support set from the Benes control bits in the secret key. */
void support_gen(gf *s, const unsigned char *c);

/* Evaluate the locator polynomial over the full support set. */
void root(gf *out, gf *f, gf *L);
void transpose_64x64(uint64_t *out, uint64_t *in);
gf eval(gf *f, gf a);
void apply_benes(unsigned char *r, const unsigned char *bits, int rev);

/* Host-side setup for loading vectors and reconstructing decode state. */
int initialisation(unsigned char *secretkeys, unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES], unsigned char *sk, gf *L, gf *g);

/* Precompute support-point powers, then build one syndrome from a ciphertext. */
void compute_inverses();
void synd(gf *out, unsigned char *r);

#ifdef __cplusplus
}
#endif

#endif /* ROOT_H */
