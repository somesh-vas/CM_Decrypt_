
#ifndef GF_H
#define GF_H

#include "common.h"

#ifdef __cplusplus
extern "C" {
#endif

gf bitrev(gf a);

/* Load/store helpers for serialized secret-key and support data. */
uint16_t load_gf(const unsigned char *src);
void store_gf(unsigned char *dest, gf a);
uint32_t load4(const unsigned char *in);
void store8(unsigned char *out, uint64_t in);
uint64_t load8(const unsigned char *in);

/* Host-side finite-field arithmetic used during setup and validation. */
gf gf_mul(gf a, gf b);
gf gf_frac(gf a, gf b);
gf gf_inv(gf a);
gf gf_add(gf a, gf b);
gf gf_iszero(gf a);
gf gf_preinv_for_table(gf den);

#ifdef __cplusplus
}
#endif

#endif /* GF_H */
