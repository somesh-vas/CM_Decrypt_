#ifndef COMMON_H
#define COMMON_H

#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
// #include <fstream>
#include <stdint.h>

#define KAT_SUCCESS          0
#define KAT_FILE_OPEN_ERROR -1
#define KAT_CRYPTO_FAILURE -4
#define KATNUM 5
#define ciphert 1
#define crypto_kem_SECRETKEYBYTES 13608
#define crypto_kem_CIPHERTEXTBYTES 156
#define GFBITS 13
#define SYS_N 4608
#define SYS_T 96
#define COND_BYTES ((1 << (GFBITS - 4)) * (2 * GFBITS - 1))
#define IRR_BYTES (SYS_T * 2)
#define PK_NROWS (SYS_T * GFBITS)
#define PK_NCOLS (SYS_N - PK_NROWS)
#define PK_ROW_BYTES ((PK_NCOLS + 7)/8)
#define SYND_BYTES ((PK_NROWS + 7)/8)
#define GFMASK ((1 << GFBITS) - 1)
#define min(a, b) ((a < b) ? a : b)
#define sb (SYND_BYTES * 8)
typedef uint16_t gf;

#endif /* COMMON_H */