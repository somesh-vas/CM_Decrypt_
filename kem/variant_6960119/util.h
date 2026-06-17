#ifndef UTIL_H
#define UTIL_H

#include <stdint.h>

#include "gf.h"

#define bitrev CRYPTO_NAMESPACE(bitrev)
#define load4 CRYPTO_NAMESPACE(load4)
#define load8 CRYPTO_NAMESPACE(load8)
#define load_gf CRYPTO_NAMESPACE(load_gf)
#define store8 CRYPTO_NAMESPACE(store8)
#define store_gf CRYPTO_NAMESPACE(store_gf)

void store_gf(unsigned char *dest, gf value);
uint16_t load_gf(const unsigned char *src);
uint32_t load4(const unsigned char *src);

void store8(unsigned char *dest, uint64_t value);
uint64_t load8(const unsigned char *src);

/* Reverse the bit order of a field element and drop the unused high bits. */
gf bitrev(gf value);

#endif /* UTIL_H */
